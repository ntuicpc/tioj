class SubmissionsController < ApplicationController
  before_action :authenticate_user!, only: [:new, :create]
  before_action :authenticate_admin!, except: [:index, :show, :create, :new, :verdict]
  before_action :set_submissions
  before_action :set_submission, only: [:rejudge, :show, :edit, :update, :destroy]
  before_action :set_compiler, only: [:new, :create, :edit, :update]
  before_action :check_compiler, only: [:create, :update]
  before_action :set_contest, only: [:show]
  before_action :set_problem, only: [:show]
  layout :set_contest_layout, only: [:show, :index, :new]
  helper_method :td_list_to_arr

  def rejudge
    @submission.submission_tasks.destroy_all
    @submission.update(:result => "queued", :score => 0, :total_time => nil, :total_memory => nil, :message => nil)
    ActionCable.server.broadcast('fetch', {type: 'notify', action: 'rejudge', submission_id: @submission.id})
    redirect_back fallback_location: root_path
  end

  def index
    @submissions = @submissions.order(id: :desc).page(params[:page]).preload(:user, :compiler, :problem)
    unless user_signed_in? and current_user.admin?
      @submissions = @submissions.preload(:contest)
    end
  end

  def show
    unless (user_signed_in? and current_user.admin?) or (user_signed_in? and current_user.id == @submission.user_id) or not @submission.contest
      if Time.now <= @submission.contest.end_time
        redirect_to contest_path(@submission.contest), :notice => 'Submission is censored during contest.'
        return
      elsif @submission.created_at >= @contest.end_time - @contest.freeze_time * 60
        redirect_to contest_path(@submission.contest), :notice => 'Submission is censored before unfreeze.'
        return
      end
    end
    @_result = @submission.submission_tasks.index_by(&:position)
    @has_vss = @_result.empty? || @_result.values.any?{|x| x.vss}
    @tdlist = @submission.problem.testdata_sets
    @invtdlist = inverse_td_list(@submission.problem)
  end

  def new
    if params[:problem_id].blank?
      redirect_to action:'index'
      return
    end
    unless current_user.admin?
      if @problem.visible_invisible?
        redirect_to action:'index'
        return
      elsif @problem.visible_contest?
        if params[:contest_id].blank?
          redirect_to action:'index'
          return
        end
        contest = Contest.find(params[:contest_id])
        unless contest.problem_ids.include?(@problem.id) and Time.now >= contest.start_time and Time.now <= contest.end_time
          redirect_to contest_problem_path(contest, @problem), notice: 'Contest ended, cannot submit.'
          return
        end
        if Regexp.new(contest.user_whitelist, Regexp::IGNORECASE).match(current_user.username).nil?
          redirect_to contest_problem_path(contest, @problem), notice: 'You are not allowed to submit in this contest.'
          return
        end
      end
    end
    @submission = Submission.new
    @contest_id = params[:contest_id]
  end

  def create
    cd_time = @contest ? @contest.cd_time : 15
    if not current_user.admin? and not current_user.last_submit_time.blank? and Time.now - current_user.last_submit_time < cd_time
      redirect_to submissions_path, alert: 'CD time %d seconds.' % cd_time
      return
    end
    User.transaction do
      user = User.lock("LOCK IN SHARE MODE").find(current_user.id)
      if not user.update(:last_submit_time => Time.now)
        redirect_to submissions_path, alert: 'CD time %d seconds.' % cd_time
        return
      end
    end

    if params[:problem_id].blank?
      redirect_to action:'index'
      return
    end
    unless current_user.admin?
      if @problem.visible_invisible?
        redirect_to action:'index'
        return
      elsif @problem.visible_contest?
        if params[:contest_id].blank?
          redirect_to action:'index'
          return
        end
        contest = Contest.find(params[:contest_id])
        unless contest.problem_ids.include?(@problem.id) and Time.now >= contest.start_time and Time.now <= contest.end_time
          redirect_to contest_problem_path(contest, @problem), notice: 'Contest ended, cannot submit.'
          return
        end
        if Regexp.new(contest.user_whitelist, Regexp::IGNORECASE).match(current_user.username).nil?
          redirect_to contest_problem_path(contest, @problem), notice: 'You are not allowed to submit in this contest.'
          return
        end
      end
    end
    params[:submission][:code] = submission_params[:code].encode(submission_params[:code].encoding, universal_newline: true)

    #@submission = @submissions.build(submission_params)
    @submission = Submission.new(submission_params)
    @submission.user_id = current_user.id
    @submission.problem_id = params[:problem_id]
    if params[:contest_id]
      if @contest.problem_ids.include?(@submission.problem_id) and Time.now >= @contest.start_time and Time.now <= @contest.end_time
        @submission.contest_id = @contest.id
      end
    end
    respond_to do |format|
      if @submission.save
        ActionCable.server.broadcast('fetch', {type: 'notify', action: 'new', submission_id: @submission.id})
        format.html { redirect_to @submission, notice: 'Submission was successfully created.' }
        format.json { render action: 'show', status: :created, location: @submission }
      else
        format.html { render action: 'new' }
        format.json { render json: @submission.errors, status: :unprocessable_entity }
      end
    end
  end

  def edit
  end

  def update
    respond_to do |format|
      params[:submission][:code] = submission_params[:code].encode(submission_params[:code].encoding, universal_newline: true)
      if @submission.update(submission_params)
        format.html { redirect_to @submission, notice: 'Submission was successfully updated.' }
        format.json { head :no_content }
      else
        format.html { render action: 'edit' }
        format.json { render json: @submission.errors, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @submission.destroy
    respond_to do |format|
      format.html { redirect_to submissions_url }
      format.json { head :no_content }
    end
  end

  private
  def set_submissions
    @problem = Problem.find(params[:problem_id]) if params[:problem_id]
    @contest = Contest.find(params[:contest_id]) if params[:contest_id]
    @submissions = Submission
    @submissions = @submissions.where(problem_id: params[:problem_id]) if params[:problem_id]
    if params[:contest_id]
      @submissions = @submissions.where(contest_id: params[:contest_id])
      unless user_signed_in? and current_user.admin?
        if user_signed_in?
          @submissions = @submissions.where("submissions.created_at < ? or submissions.user_id = ?", @contest.end_time - @contest.freeze_time * 60, current_user.id)
        else
          @submissions = @submissions.where("submissions.created_at < ?", @contest.end_time - @contest.freeze_time * 60)
        end
        if Time.now <= @contest.end_time #and Time.now >= @contest.start_time
          #only self submission
          if user_signed_in?
            @submissions = @submissions.where(user_id: current_user.id)
          else
            @submissions = @submissions.where(user_id: 0) #just make it an empty set whatsoeveAr
            return
          end
        end
      end
    else
      @submissions = @submissions.where(contest_id: nil)
      unless user_signed_in? and current_user.admin?
        @submissions = @submissions.joins(:problem).where(problem: {visible_state: :public})
      end
    end
    @submissions = @submissions.where(problem_id: params[:filter_problem]) if not params[:filter_problem].blank?
    if not params[:filter_username].blank?
      usr_clause = User.select(:id).where('username LIKE ?', params[:filter_username]).to_sql
      @submissions = @submissions.where("user_id IN (#{usr_clause})")
    end
    @submissions = @submissions.where(user_id: params[:filter_user_id]) if not params[:filter_user_id].blank?
    @submissions = @submissions.where(result: params[:filter_status]) if not params[:filter_status].blank?
    @submissions = @submissions.where(compiler_id: params[:filter_compiler].map{|x| x.to_i}) if not params[:filter_compiler].blank?
  end

  def set_submission
    @submission = Submission.find(params[:id])
  end

  def set_contest
    @contest = @submission.contest
  end

  def set_problem
    @problem = @submission.problem
  end

  def set_compiler
    if not @problem
      @problem = @submission.problem
    end
    @compiler = Compiler.where.not(id: @problem.compilers.map{|x| x.id})
    if @contest
      @compiler = @compiler.where.not(id: @contest.compilers.map{|x| x.id})
    end
    @compiler = @compiler.order(order: :asc).to_a
  end

  def check_compiler
    unless @compiler.any? { |c| c.id == submission_params[:compiler_id].to_i }
      redirect_to submissions_path, alert: 'Invalid compiler.'
      return
    end
  end

  # Never trust parameters from the scary internet, only allow the white list through.
  def submission_params
    params.require(:submission).permit(:code, :compiler_id, :problem_id)
  end
end

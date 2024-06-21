class ProxyJudgeJob < ApplicationJob
  queue_as :default

  # def initialize(*args)
  #   super
  #   Rails.logger.info "args = #{args}"
  # end

  def perform(submission, problem)
    code = submission.code_content.code

    begin
      case submission.compiler.format_type # XXX: hack for exactly same code
      when "language-c", "language-cpp"
        code << "\n// tioj-proxy - " << rand(8**36).to_s(36)
      when "language-haskell"
        code << "\n-- tioj-proxy - " << rand(8**36).to_s(36)
      when "language-python"
        code << "\n# tioj-proxy - " << rand(8**36).to_s(36)
      end

      # Rails.logger.info code
      # Rails.logger.info "proxyjudge_type = #{problem.proxyjudge_type}"
      # Rails.logger.info "proxyjudge_args = #{problem.proxyjudge_args}"
      # Rails.logger.info submission.compiler
      # return

      case problem.proxyjudge_type.to_sym
      when :codeforces
        @proxy = Judges::CF.new()
      when :poj
        @proxy = Judges::POJ.new()
      else
        raise 'Unknown problem.proxyjudge_type'
      end

      @proxy.submit!(problem.proxyjudge_args, submission.compiler.name, code)

      submission.result = "received"
      submission.save
      # TODO check broadcast working?
      ActionCable.server.broadcast("submission_#{submission.id}_overall",
                                   {result: 'received', id: submission.id})

      # TODO shall we set a timeout or max retry?
      until @proxy.done? do
        sleep 3
      end
      @proxy.summary!
      submission.result = @proxy.verdict
      submission.total_time = @proxy.time
      submission.total_memory = @proxy.memory
      submission.save
      ActionCable.server.broadcast("submission_#{submission.id}_overall",
         [:id, :score, :result, :total_time, :total_memory, :message].map{|attr|
           [attr, submission.read_attribute(attr)]
         }.to_h
      )
    rescue Exception => e
      Rails.logger.error e
      submission.result = "JE"
      submission.save
    end
  end
end

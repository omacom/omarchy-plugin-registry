class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "Omarchy Plugins <registry@omarchy.org>")
  layout "mailer"
end

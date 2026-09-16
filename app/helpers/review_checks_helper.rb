module ReviewChecksHelper
  def review_check_badge(status)
    label, tone = case status
    when "passed", "pass" then [ "Passed", "ok" ]
    when "flagged", "flag" then [ "Flagged", "warning" ]
    when "failed", "fail" then [ "Failed", "danger" ]
    when "not_applicable" then [ "Not applicable", nil ]
    when "skipped" then [ "Not run", nil ]
    else [ "Not recorded", nil ]
    end
    tag.span(label, class: [ "badge", ("badge--#{tone}" if tone) ])
  end
end

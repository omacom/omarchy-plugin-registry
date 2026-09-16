# Local processor-container fixture only. Never auto-loaded by Rails tests.
# No external calls,
# submitted code, secrets or actual model. Returns a deterministic JSON verdict.
require "bundler/setup"
require "puma"
require "json"

app = ->(_env) do
  body = JSON.generate({ id: "fixture", object: "chat.completion", model: "fixture-model",
                         choices: [ { index: 0, message: { role: "assistant", content: JSON.generate({ verdict: "pass", reasons: [] }) }, finish_reason: "stop" } ],
                         usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })
  [ 200, { "content-type" => "application/json", "content-length" => body.bytesize.to_s }, [ body ] ]
end
server = Puma::Server.new(app, Puma::Events.new, { min_threads: 0, max_threads: 1 })
server.add_tcp_listener("0.0.0.0", 8081)
server.run.join

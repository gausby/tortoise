Code.require_file("./support/test_tcp_tunnel.exs", __DIR__)

# make certs for tests using the SSL transport
:ok = :ct_helper.make_certs_in_ets()

{:ok, _} = Tortoise311.Integration.TestTCPTunnel.start_link()

ExUnit.start(capture_log: true)

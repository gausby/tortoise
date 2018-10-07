defmodule Tortoise.ConnectionTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection

  alias Tortoise.Integration.{ScriptedMqttServer, ScriptedTransport}
  alias Tortoise.Connection
  alias Tortoise.Connection.Inflight
  alias Tortoise.Package

  setup context do
    # the Package.Connect encoder is capable of casting a client id
    # specified as an atom into a binary, but we do it here manually
    # because we are making assertions on the connect package when it
    # is received by the server; if we don't do it like this they
    # would be different because the decoder will convert the
    # client_id into a binary.
    client_id = Atom.to_string(context.test)

    {:ok, %{client_id: client_id}}
  end

  def setup_scripted_mqtt_server(_context) do
    {:ok, pid} = ScriptedMqttServer.start_link()
    {:ok, %{scripted_mqtt_server: pid}}
  end

  def setup_scripted_mqtt_server_ssl(_context) do
    certs_opts = :ct_helper.get_certs_from_ets()

    server_opts = [
      transport: Tortoise.Transport.SSL,
      opts: [:binary, {:active, false}, {:packet, :raw} | certs_opts]
    ]

    {:ok, pid} = ScriptedMqttServer.start_link(server_opts)

    {:ok,
     %{
       scripted_mqtt_server: pid,
       key: certs_opts[:key],
       cert: certs_opts[:cert],
       cacerts: certs_opts[:cacerts]
     }}
  end

  def setup_connection_and_perform_handshake(%{
        client_id: client_id,
        scripted_mqtt_server: scripted_mqtt_server
      }) do
    script = [
      {:receive, %Package.Connect{client_id: client_id}},
      {:send, %Package.Connack{reason: :success, session_present: false}}
    ]

    {:ok, {ip, port}} = ScriptedMqttServer.enact(scripted_mqtt_server, script)

    opts = [
      client_id: client_id,
      server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
      handler: {TestHandler, [parent: self()]}
    ]

    assert {:ok, connection_pid} = Connection.start_link(opts)

    assert_receive {ScriptedMqttServer, {:received, %Package.Connect{}}}
    assert_receive {ScriptedMqttServer, :completed}

    {:ok, %{connection_pid: connection_pid}}
  end

  describe "successful connect" do
    setup [:setup_scripted_mqtt_server]

    test "without present state", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}
      expected_connack = %Package.Connack{reason: :success, session_present: false}

      script = [{:receive, connect}, {:send, expected_connack}]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "reconnect with present state", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}
      reconnect = %Package.Connect{connect | clean_start: false}

      script = [
        {:receive, connect},
        {:send, %Package.Connack{reason: :success, session_present: false}},
        :disconnect,
        {:receive, reconnect},
        {:send, %Package.Connack{reason: :success, session_present: true}}
      ]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, {:received, ^reconnect}}
      assert_receive {ScriptedMqttServer, :completed}
    end
  end

  describe "unsuccessful connect" do
    setup [:setup_scripted_mqtt_server]

    test "unsupported protocol version", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}

      script = [
        {:receive, connect},
        {:send, %Package.Connack{reason: {:refused, :unsupported_protocol_version}}}
      ]

      true = Process.unlink(context.scripted_mqtt_server)
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, pid} = Connection.start_link(opts)

      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
      assert_receive {:EXIT, ^pid, {:connection_failed, :unsupported_protocol_version}}
    end

    test "reject client identifier", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{reason: {:refused, :client_identifier_not_valid}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
      assert_receive {:EXIT, ^pid, {:connection_failed, :client_identifier_not_valid}}
    end

    test "server unavailable", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{reason: {:refused, :server_unavailable}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
      assert_receive {:EXIT, ^pid, {:connection_failed, :server_unavailable}}
    end

    test "bad user name or password", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{reason: {:refused, :bad_user_name_or_password}}
      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
      assert_receive {:EXIT, ^pid, {:connection_failed, :bad_user_name_or_password}}
    end

    test "not authorized", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{reason: {:refused, :not_authorized}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}

      assert_receive {:EXIT, ^pid, {:connection_failed, :not_authorized}}
    end
  end

  describe "subscriptions" do
    setup [:setup_scripted_mqtt_server]

    test "successful subscription", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}

      default_subscription_opts = [
        no_local: false,
        retain_as_published: false,
        retain_handling: 1
      ]

      subscription_foo =
        Enum.into(
          [{"foo", [{:qos, 0} | default_subscription_opts]}],
          %Package.Subscribe{identifier: 1}
        )

      subscription_bar =
        Enum.into(
          [{"bar", [{:qos, 1} | default_subscription_opts]}],
          %Package.Subscribe{identifier: 2}
        )

      subscription_baz =
        Enum.into(
          [{"baz", [{:qos, 2} | default_subscription_opts]}],
          %Package.Subscribe{identifier: 3}
        )

      script = [
        {:receive, connect},
        {:send, %Package.Connack{reason: :success, session_present: false}},
        # subscribe to foo with qos 0
        {:receive, subscription_foo},
        {:send, %Package.Suback{identifier: 1, acks: [{:ok, 0}]}},
        # subscribe to bar with qos 0
        {:receive, subscription_bar},
        {:send, %Package.Suback{identifier: 2, acks: [{:ok, 1}]}},
        {:receive, subscription_baz},
        {:send, %Package.Suback{identifier: 3, acks: [{:ok, 2}]}}
      ]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {TestHandler, [parent: self()]}
      ]

      # connection
      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}

      # subscribe to a foo
      :ok = Tortoise.Connection.subscribe_sync(client_id, {"foo", 0}, identifier: 1)
      assert_receive {ScriptedMqttServer, {:received, ^subscription_foo}}
      assert Enum.member?(Tortoise.Connection.subscriptions(client_id), {"foo", 0})
      assert_receive {{TestHandler, :subscription}, %{status: :up, topic_filter: "foo"}}

      # subscribe to a bar
      assert {:ok, ref} = Tortoise.Connection.subscribe(client_id, {"bar", 1}, identifier: 2)
      assert_receive {{Tortoise, ^client_id}, ^ref, :ok}
      assert_receive {ScriptedMqttServer, {:received, ^subscription_bar}}
      assert_receive {{TestHandler, :subscription}, %{status: :up, topic_filter: "bar"}}

      # subscribe to a baz
      assert {:ok, ref} = Tortoise.Connection.subscribe(client_id, "baz", qos: 2, identifier: 3)
      assert_receive {{Tortoise, ^client_id}, ^ref, :ok}
      assert_receive {ScriptedMqttServer, {:received, ^subscription_baz}}
      assert_receive {{TestHandler, :subscription}, %{status: :up, topic_filter: "baz"}}

      # foo, bar, and baz should now be in the subscription list
      subscriptions = Tortoise.Connection.subscriptions(client_id)
      assert Enum.member?(subscriptions, {"foo", 0})
      assert Enum.member?(subscriptions, {"bar", 1})
      assert Enum.member?(subscriptions, {"baz", 2})

      # done
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "successful unsubscribe", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}
      unsubscribe_foo = %Package.Unsubscribe{identifier: 2, topics: ["foo"]}
      unsubscribe_bar = %Package.Unsubscribe{identifier: 3, topics: ["bar"]}

      script = [
        {:receive, connect},
        {:send, %Package.Connack{reason: :success, session_present: false}},
        {:receive,
         %Package.Subscribe{
           topics: [
             {"foo", [qos: 0, no_local: false, retain_as_published: false, retain_handling: 1]},
             {"bar", [qos: 2, no_local: false, retain_as_published: false, retain_handling: 1]}
           ],
           identifier: 1
         }},
        {:send, %Package.Suback{acks: [ok: 0, ok: 2], identifier: 1}},
        # unsubscribe foo
        {:receive, unsubscribe_foo},
        {:send, %Package.Unsuback{results: [:success], identifier: 2}},
        # unsubscribe bar
        {:receive, unsubscribe_bar},
        {:send, %Package.Unsuback{results: [:success], identifier: 3}}
      ]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      subscribe = %Package.Subscribe{
        topics: [
          {"foo", [qos: 0, no_local: false, retain_as_published: false, retain_handling: 1]},
          {"bar", [qos: 2, no_local: false, retain_as_published: false, retain_handling: 1]}
        ],
        identifier: 1
      }

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {TestHandler, [parent: self()]},
        subscriptions: subscribe
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}

      assert_receive {ScriptedMqttServer, {:received, ^subscribe}}

      assert_receive {{TestHandler, :subscription}, %{status: :up, topic_filter: "foo"}}
      assert_receive {{TestHandler, :subscription}, %{status: :up, topic_filter: "bar"}}

      # now let us try to unsubscribe from foo
      :ok = Tortoise.Connection.unsubscribe_sync(client_id, "foo", identifier: 2)
      assert_receive {ScriptedMqttServer, {:received, ^unsubscribe_foo}}
      # the callback handler should get a :down message for the foo subscription
      assert_receive {{TestHandler, :subscription}, %{status: :down, topic_filter: "foo"}}

      assert %Package.Subscribe{topics: [{"bar", qos: 2}]} =
               Tortoise.Connection.subscriptions(client_id)

      # and unsubscribe from bar
      assert {:ok, ref} = Tortoise.Connection.unsubscribe(client_id, "bar", identifier: 3)
      assert_receive {{Tortoise, ^client_id}, ^ref, :ok}
      assert_receive {ScriptedMqttServer, {:received, ^unsubscribe_bar}}
      # the callback handler should get a :down message for the bar subscription
      assert_receive {{TestHandler, :subscription}, %{status: :down, topic_filter: "bar"}}
      assert %Package.Subscribe{topics: []} = Tortoise.Connection.subscriptions(client_id)
      assert_receive {ScriptedMqttServer, :completed}
    end
  end

  describe "encrypted connection" do
    setup [:setup_scripted_mqtt_server_ssl]

    test "successful connect", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}
      expected_connack = %Package.Connack{reason: :success, session_present: false}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server:
          {Tortoise.Transport.SSL,
           [
             host: ip,
             port: port,
             key: context.key,
             cert: context.cert,
             verify: :verify_peer,
             cacerts: context.cacerts(),
             server_name_indication: :disable
           ]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}, 2000
      assert_receive {ScriptedMqttServer, :completed}, 2000
    end

    test "successful connect (no certificate verification)", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}
      expected_connack = %Package.Connack{reason: :success, session_present: false}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server:
          {Tortoise.Transport.SSL,
           [
             host: ip,
             port: port,
             key: context.key,
             cert: context.cert,
             verify: :verify_none
           ]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}, 5000
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "unsuccessful connect", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, [])

      opts = [
        client_id: client_id,
        server:
          {Tortoise.Transport.SSL,
           [
             host: ip,
             port: port,
             key: context.key,
             cert: context.cert
           ]},
        handler: {Tortoise.Handler.Default, []}
      ]

      # Need to pass :cacerts/:cacerts_file option, or set :verify to
      # :verify_none to opt out of server cert verification
      assert {:ok, pid} = Connection.start_link(opts)
      assert_receive {:EXIT, ^pid, :no_cacartfile_specified}
    end
  end

  describe "Connection failures" do
    test "nxdomain", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}
      expected_connack = %Package.Connack{reason: :success, session_present: false}
      refusal = {:error, :nxdomain}

      {:ok, _} =
        ScriptedTransport.start_link(
          {'localhost', 1883},
          script: [
            {:refute_connection, refusal},
            {:refute_connection, refusal},
            {:expect, connect},
            {:dispatch, expected_connack}
          ]
        )

      assert {:ok, _pid} =
               Tortoise.Connection.start_link(
                 client_id: client_id,
                 server: {ScriptedTransport, host: 'localhost', port: 1883},
                 backoff: [min_interval: 1],
                 handler: {Tortoise.Handler.Logger, []}
               )

      assert_receive {ScriptedTransport, {:refute_connection, ^refusal}}
      assert_receive {ScriptedTransport, {:refute_connection, ^refusal}}
      assert_receive {ScriptedTransport, :connected}
      assert_receive {ScriptedTransport, {:received, ^connect}}
    end

    test "server rebooting", context do
      # This test tries to mimic the observed behavior of a vernemq
      # server rebooting while we are connected to it: First it will
      # send an `{:error, :close}`, then it will refute the connection
      # with `{:error, :econnrefused}`, and then it will finally start
      # accepting connections
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}
      expected_connack = %Package.Connack{reason: :success, session_present: false}
      refusal = {:error, :econnrefused}

      {:ok, _pid} =
        ScriptedTransport.start_link(
          {'localhost', 1883},
          script: [
            # first connect
            {:expect, connect},
            {:dispatch, expected_connack},
            # then close the connection, refuse the connection
            {:close_connection, 0},
            {:refute_connection, refusal},
            {:refute_connection, refusal},
            # finally start accepting connections again
            {:expect, %Package.Connect{connect | clean_start: false}},
            {:dispatch, expected_connack}
          ]
        )

      assert {:ok, _pid} =
               Tortoise.Connection.start_link(
                 client_id: client_id,
                 server: {ScriptedTransport, host: 'localhost', port: 1883},
                 backoff: [min_interval: 0],
                 handler: {Tortoise.Handler.Logger, []}
               )

      assert_receive {ScriptedTransport, :connected}
      assert_receive {ScriptedTransport, :closed_connection}
      assert_receive {ScriptedTransport, {:refute_connection, ^refusal}}
      assert_receive {ScriptedTransport, {:refute_connection, ^refusal}}
      assert_receive {ScriptedTransport, :connected}
      assert_receive {ScriptedTransport, :completed}
    end

    test "server protocol violation", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}

      {:ok, _pid} =
        ScriptedTransport.start_link(
          {'localhost', 1883},
          script: [
            {:expect, connect},
            {:dispatch, %Package.Publish{topic: "foo/bar"}}
          ]
        )

      assert {:ok, pid} =
               Tortoise.Connection.start_link(
                 client_id: client_id,
                 server: {ScriptedTransport, host: 'localhost', port: 1883},
                 handler: {Tortoise.Handler.Logger, []}
               )

      assert_receive {ScriptedTransport, :connected}
      assert_receive {ScriptedTransport, {:received, %Package.Connect{}}}

      assert_receive {:EXIT, ^pid, {:protocol_violation, violation}}
      assert %{expected: [Tortoise.Package.Connack, Tortoise.Package.Auth], got: _} = violation
      assert_receive {ScriptedTransport, :completed}
    end
  end

  describe "socket subscription" do
    setup [:setup_scripted_mqtt_server]

    test "return error if asking for a connection on an non-existent connection", context do
      assert {:error, :unknown_connection} = Connection.connection(context.client_id)
    end

    test "receive a socket from a connection", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}
      expected_connack = %Package.Connack{reason: :success, session_present: false}

      script = [{:receive, connect}, {:send, expected_connack}]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}

      assert {:ok, {Tortoise.Transport.Tcp, _socket}} =
               Connection.connection(client_id, timeout: 500)

      assert_receive {ScriptedMqttServer, :completed}
    end

    test "timeout on a socket from a connection", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_start: true}

      script = [{:receive, connect}, :pause]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :paused}

      assert {:error, :timeout} = Connection.connection(client_id, timeout: 5)

      send(context.scripted_mqtt_server, :continue)
      assert_receive {ScriptedMqttServer, :completed}
    end
  end

  describe "life-cycle" do
    setup [:setup_scripted_mqtt_server]

    test "connect and cleanly disconnect", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{reason: :success, session_present: false}
      disconnect = %Package.Disconnect{}

      script = [{:receive, connect}, {:send, expected_connack}, {:receive, disconnect}]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      handler = {TestHandler, [parent: self()]}

      opts = [
        client_id: client_id,
        server: {Tortoise.Transport.Tcp, [host: ip, port: port]},
        handler: handler
      ]

      assert {:ok, pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}

      cs_pid = Connection.Supervisor.whereis(client_id)
      cs_ref = Process.monitor(cs_pid)

      inflight_pid = Connection.Inflight.whereis(client_id)
      receiver_pid = Connection.Receiver.whereis(client_id)

      assert :ok = Tortoise.Connection.disconnect(client_id)

      assert_receive {ScriptedMqttServer, {:received, ^disconnect}}
      assert_receive {:EXIT, ^pid, :shutdown}

      assert_receive {ScriptedMqttServer, :completed}

      assert_receive {:DOWN, ^cs_ref, :process, ^cs_pid, :shutdown}
      refute Process.alive?(inflight_pid)
      refute Process.alive?(receiver_pid)

      # The user defined handler should have the following callbacks
      # triggered during this exchange
      {handler_mod, handler_init_opts} = handler
      assert_receive {{^handler_mod, :init}, ^handler_init_opts}
      assert_receive {{^handler_mod, :connection}, :up}
      assert_receive {{^handler_mod, :terminate}, :shutdown}
      refute_receive {{^handler_mod, _}, _}
    end
  end

  describe "ping" do
    setup [:setup_scripted_mqtt_server, :setup_connection_and_perform_handshake]

    test "send pingreq and receive a pingresp", %{client_id: client_id} = context do
      {:ok, _} = Tortoise.Events.register(client_id, :status)
      assert_receive {{Tortoise, ^client_id}, :status, :connected}

      ping_request = %Package.Pingreq{}
      expected_pingresp = %Package.Pingresp{}
      script = [{:receive, ping_request}, {:send, expected_pingresp}]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      {:ok, ref} = Connection.ping(context.client_id)
      assert_receive {ScriptedMqttServer, {:received, ^ping_request}}
      assert_receive {{Tortoise, ^client_id}, {Package.Pingreq, ^ref}, _}
    end

    test "ping_sync/2", %{client_id: client_id} = context do
      {:ok, _} = Tortoise.Events.register(client_id, :status)
      assert_receive {{Tortoise, ^client_id}, :status, :connected}

      ping_request = %Package.Pingreq{}
      expected_pingresp = %Package.Pingresp{}
      script = [{:receive, ping_request}, {:send, expected_pingresp}]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      {parent, ref} = {self(), make_ref()}

      spawn_link(fn ->
        send(parent, {{:child_result, ref}, Connection.ping_sync(client_id)})
      end)

      assert_receive {ScriptedMqttServer, {:received, ^ping_request}}
      assert_receive {{:child_result, ^ref}, {:ok, time}}
      assert_receive {ScriptedMqttServer, :completed}
    end
  end

  describe "Protocol violations" do
    setup [:setup_scripted_mqtt_server, :setup_connection_and_perform_handshake]

    test "Receiving a connect from the server is a protocol violation", context do
      Process.flag(:trap_exit, true)
      unexpected_connect = %Package.Connect{client_id: "foo"}
      script = [{:send, unexpected_connect}]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid
      expected_reason = {:protocol_violation, {:unexpected_package, unexpected_connect}}
      assert_receive {:EXIT, ^pid, ^expected_reason}

      # the terminate/2 callback should get triggered
      assert_receive {{TestHandler, :terminate}, ^expected_reason}
    end

    test "Receiving a connack after the handshake is a protocol violation", context do
      Process.flag(:trap_exit, true)
      unexpected_connack = %Package.Connack{reason: :success}
      script = [{:send, unexpected_connack}]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid
      expected_reason = {:protocol_violation, {:unexpected_package, unexpected_connack}}
      assert_receive {:EXIT, ^pid, ^expected_reason}

      # the terminate/2 callback should get triggered
      assert_receive {{TestHandler, :terminate}, ^expected_reason}
    end

    test "Receiving a ping request from the server is a protocol violation", context do
      Process.flag(:trap_exit, true)
      unexpected_pingreq = %Package.Pingreq{}
      script = [{:send, unexpected_pingreq}]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid
      expected_reason = {:protocol_violation, {:unexpected_package, unexpected_pingreq}}
      assert_receive {:EXIT, ^pid, ^expected_reason}

      # the terminate/2 callback should get triggered
      assert_receive {{TestHandler, :terminate}, ^expected_reason}
    end

    test "Receiving a subscribe package from the server is a protocol violation", context do
      Process.flag(:trap_exit, true)

      unexpected_subscribe = %Package.Subscribe{
        topics: [
          {"foo/bar", [qos: 0, no_local: false, retain_as_published: false, retain_handling: 1]}
        ],
        identifier: 1
      }

      script = [{:send, unexpected_subscribe}]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid
      expected_reason = {:protocol_violation, {:unexpected_package, unexpected_subscribe}}
      assert_receive {:EXIT, ^pid, ^expected_reason}

      # the terminate/2 callback should get triggered
      assert_receive {{TestHandler, :terminate}, ^expected_reason}
    end

    test "Receiving an unsubscribe package from the server is a protocol violation", context do
      Process.flag(:trap_exit, true)

      unexpected_unsubscribe = %Package.Unsubscribe{
        topics: ["foo/bar"],
        identifier: 1
      }

      script = [{:send, unexpected_unsubscribe}]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid
      expected_reason = {:protocol_violation, {:unexpected_package, unexpected_unsubscribe}}
      assert_receive {:EXIT, ^pid, ^expected_reason}

      # the terminate/2 callback should get triggered
      assert_receive {{TestHandler, :terminate}, ^expected_reason}
    end
  end

  describe "Publish with QoS=0" do
    setup [:setup_scripted_mqtt_server, :setup_connection_and_perform_handshake]

    test "Receiving a publish", context do
      Process.flag(:trap_exit, true)
      publish = %Package.Publish{topic: "foo/bar", qos: 0}

      script = [{:send, publish}]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid

      refute_receive {:EXIT, ^pid, {:protocol_violation, {:unexpected_package, ^publish}}}
      assert_receive {ScriptedMqttServer, :completed}

      # the handle message callback should have been called
      assert_receive {{TestHandler, :handle_message}, %{topic: "foo/bar", payload: nil}}
    end
  end

  describe "Publish with QoS=1" do
    setup [:setup_scripted_mqtt_server, :setup_connection_and_perform_handshake]

    test "incoming publish with QoS=1", context do
      Process.flag(:trap_exit, true)
      publish = %Package.Publish{identifier: 1, topic: "foo/bar", qos: 1}
      expected_puback = %Package.Puback{identifier: 1}

      script = [
        {:send, publish},
        {:receive, expected_puback}
      ]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      assert_receive {ScriptedMqttServer, :completed}

      # the handle message callback should have been called
      assert_receive {{TestHandler, :handle_message}, %{topic: "foo/bar", payload: nil}}
    end

    test "outgoing publish with QoS=1", context do
      Process.flag(:trap_exit, true)
      publish = %Package.Publish{identifier: 1, topic: "foo/bar", qos: 1}
      puback = %Package.Puback{identifier: 1}

      script = [
        {:receive, publish},
        {:send, puback}
      ]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid

      client_id = context.client_id
      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})

      refute_receive {:EXIT, ^pid, {:protocol_violation, {:unexpected_package, _}}}
      assert_receive {ScriptedMqttServer, {:received, ^publish}}
      assert_receive {ScriptedMqttServer, :completed}
      # the caller should receive an :ok for the ref when it is published
      assert_receive {{Tortoise, ^client_id}, {Package.Publish, ^ref}, :ok}
    end

    test "outgoing publish with QoS=1 (sync call)", %{client_id: client_id} = context do
      Process.flag(:trap_exit, true)
      publish = %Package.Publish{identifier: 1, topic: "foo/bar", qos: 1}
      puback = %Package.Puback{identifier: 1}

      script = [
        {:receive, publish},
        {:send, puback}
      ]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      # setup a blocking call
      {parent, test_ref} = {self(), make_ref()}

      spawn_link(fn ->
        test_result = Inflight.track_sync(client_id, {:outgoing, publish})
        send(parent, {:sync_call_result, test_ref, test_result})
      end)

      pid = context.connection_pid
      refute_receive {:EXIT, ^pid, {:protocol_violation, {:unexpected_package, _}}}
      assert_receive {ScriptedMqttServer, {:received, ^publish}}
      assert_receive {ScriptedMqttServer, :completed}
      # the caller should receive an :ok for the ref when it is published
      assert_receive {:sync_call_result, ^test_ref, :ok}
    end
  end

  describe "Publish with QoS=2" do
    setup [:setup_scripted_mqtt_server, :setup_connection_and_perform_handshake]

    test "incoming publish with QoS=2", context do
      Process.flag(:trap_exit, true)
      publish = %Package.Publish{identifier: 1, topic: "foo/bar", qos: 2}
      expected_pubrec = %Package.Pubrec{identifier: 1}
      pubrel = %Package.Pubrel{identifier: 1}
      expected_pubcomp = %Package.Pubcomp{identifier: 1}

      script = [
        {:send, publish},
        {:receive, expected_pubrec},
        {:send, pubrel},
        {:receive, expected_pubcomp}
      ]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid

      refute_receive {:EXIT, ^pid, {:protocol_violation, {:unexpected_package, _}}}
      assert_receive {ScriptedMqttServer, :completed}

      # the handle message callback should have been called
      assert_receive {{TestHandler, :handle_message}, %{topic: "foo/bar", payload: nil}}
    end

    test "outgoing publish with QoS=2", context do
      Process.flag(:trap_exit, true)
      publish = %Package.Publish{identifier: 1, topic: "foo/bar", qos: 2}
      pubrec = %Package.Pubrec{identifier: 1}
      pubrel = %Package.Pubrel{identifier: 1}
      pubcomp = %Package.Pubcomp{identifier: 1}

      script = [
        {:receive, publish},
        {:send, pubrec},
        {:receive, pubrel},
        {:send, pubcomp}
      ]

      {:ok, _} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)
      pid = context.connection_pid

      client_id = context.client_id
      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})

      refute_receive {:EXIT, ^pid, {:protocol_violation, {:unexpected_package, _}}}
      assert_receive {ScriptedMqttServer, {:received, ^publish}}
      assert_receive {ScriptedMqttServer, {:received, ^pubrel}}
      assert_receive {ScriptedMqttServer, :completed}
      assert_receive {{Tortoise, ^client_id}, {Package.Publish, ^ref}, :ok}
    end
  end
end

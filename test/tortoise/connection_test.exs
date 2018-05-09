Code.require_file("../support/scripted_mqtt_server.exs", __DIR__)

defmodule Tortoise.ConnectionTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection

  alias Tortoise.Integration.ScriptedMqttServer
  alias Tortoise.Connection
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

  describe "successful connect" do
    setup [:setup_scripted_mqtt_server]

    test "without present state", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_session: true}
      expected_connack = %Package.Connack{status: :accepted, session_present: false}

      script = [{:receive, connect}, {:send, expected_connack}]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "reconnect with present state", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_session: true}
      reconnect = %Package.Connect{connect | clean_session: false}

      script = [
        {:receive, connect},
        {:send, %Package.Connack{status: :accepted, session_present: false}},
        :disconnect,
        {:receive, reconnect},
        {:send, %Package.Connack{status: :accepted, session_present: true}}
      ]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
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

    test "unacceptable protocol version", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}

      script = [
        {:receive, connect},
        {:send, %Package.Connack{status: {:refused, :unacceptable_protocol_version}}}
      ]

      true = Process.unlink(context.scripted_mqtt_server)
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:error, {:connection_failed, :unacceptable_protocol_version}} ==
               Connection.start_link(opts)

      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "identifier rejected", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :identifier_rejected}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:error, {:connection_failed, :identifier_rejected}} == Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "server unavailable", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :server_unavailable}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:error, {:connection_failed, :server_unavailable}} == Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "bad user name or password", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :bad_user_name_or_password}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:error, {:connection_failed, :bad_user_name_or_password}} ==
               Connection.start_link(opts)

      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "not authorized", context do
      Process.flag(:trap_exit, true)
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :not_authorized}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
        handler: {Tortoise.Handler.Default, []}
      ]

      assert {:error, {:connection_failed, :not_authorized}} == Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}
      assert_receive {ScriptedMqttServer, :completed}
    end
  end

  describe "subscriptions" do
    setup [:setup_scripted_mqtt_server]

    test "successful subscription", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_session: true}
      subscription_foo = Enum.into([{"foo", 0}], %Package.Subscribe{identifier: 1})
      subscription_bar = Enum.into([{"bar", 0}], %Package.Subscribe{identifier: 2})

      script = [
        {:receive, connect},
        {:send, %Package.Connack{status: :accepted, session_present: false}},
        # subscribe to foo with qos 0
        {:receive, subscription_foo},
        {:send, %Package.Suback{identifier: 1, acks: [{:ok, 0}]}},
        # subscribe to bar with qos 0
        {:receive, subscription_bar},
        {:send, %Package.Suback{identifier: 2, acks: [{:ok, 0}]}}
      ]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
        handler: {Tortoise.Handler.Default, []}
      ]

      # connection
      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}

      # subscribe to a foo
      :ok = Tortoise.Connection.subscribe(client_id, {"foo", 0}, identifier: 1)
      assert_receive {ScriptedMqttServer, {:received, ^subscription_foo}}
      assert Enum.member?(Tortoise.Connection.subscriptions(client_id), {"foo", 0})

      # subscribe to a bar
      :ok = Tortoise.Connection.subscribe(client_id, {"bar", 0}, identifier: 2)
      assert_receive {ScriptedMqttServer, {:received, ^subscription_bar}}
      # both foo and bar should now be in the subscription list
      subscriptions = Tortoise.Connection.subscriptions(client_id)
      assert Enum.member?(subscriptions, {"foo", 0})
      assert Enum.member?(subscriptions, {"bar", 0})

      # done
      assert_receive {ScriptedMqttServer, :completed}
    end

    test "successful unsubscribe", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_session: true}
      unsubscribe_foo = %Package.Unsubscribe{identifier: 2, topics: ["foo"]}
      unsubscribe_bar = %Package.Unsubscribe{identifier: 3, topics: ["bar"]}

      script = [
        {:receive, connect},
        {:send, %Package.Connack{status: :accepted, session_present: false}},
        {:receive, %Package.Subscribe{topics: [{"foo", 0}, {"bar", 2}], identifier: 1}},
        {:send, %Package.Suback{acks: [ok: 0, ok: 2], identifier: 1}},
        # unsubscribe foo
        {:receive, unsubscribe_foo},
        {:send, %Package.Unsuback{identifier: 2}},
        # unsubscribe bar
        {:receive, unsubscribe_bar},
        {:send, %Package.Unsuback{identifier: 3}}
      ]

      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      opts = [
        client_id: client_id,
        server: {:tcp, ip, port},
        handler: {Tortoise.Handler.Default, []},
        subscriptions: %Package.Subscribe{topics: [{"foo", 0}, {"bar", 2}], identifier: 1}
      ]

      assert {:ok, _pid} = Connection.start_link(opts)
      assert_receive {ScriptedMqttServer, {:received, ^connect}}

      # now let us try to unsubscribe from foo
      :ok = Tortoise.Connection.unsubscribe(client_id, "foo", identifier: 2)
      assert_receive {ScriptedMqttServer, {:received, ^unsubscribe_foo}}

      assert %Package.Subscribe{topics: [{"bar", 2}]} =
               Tortoise.Connection.subscriptions(client_id)

      # and unsubscribe from bar
      :ok = Tortoise.Connection.unsubscribe(client_id, "bar", identifier: 3)
      assert_receive {ScriptedMqttServer, {:received, ^unsubscribe_bar}}
      assert %Package.Subscribe{topics: []} = Tortoise.Connection.subscriptions(client_id)

      assert_receive {ScriptedMqttServer, :completed}
    end
  end
end

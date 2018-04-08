Code.require_file("../../support/scripted_mqtt_server.exs", __DIR__)

defmodule Tortoise.Connection.ConnectorTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Connector

  alias Tortoise.Integration.ScriptedMqttServer
  alias Tortoise.Connection.Connector
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

      assert {:ok, socket, ^expected_connack} = Connector.init({:gen_tcp, ip, port}, connect)
      assert is_port(socket)
      assert_receive {:server_received, ^connect}
    end

    test "with present state", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id, clean_session: false}
      expected_connack = %Package.Connack{status: :accepted, session_present: true}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      assert {:ok, socket, ^expected_connack} = Connector.init({:gen_tcp, ip, port}, connect)
      assert is_port(socket)
      assert_receive {:server_received, ^connect}
    end
  end

  describe "unsuccessful connect" do
    setup [:setup_scripted_mqtt_server]

    test "unacceptable protocol version", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :unacceptable_protocol_version}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      assert {:error, ^expected_connack} = Connector.init({:gen_tcp, ip, port}, connect)
      assert_receive {:server_received, ^connect}
    end

    test "identifier rejected", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :identifier_rejected}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      assert {:error, ^expected_connack} = Connector.init({:gen_tcp, ip, port}, connect)
      assert_receive {:server_received, ^connect}
    end

    test "server unavailable", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :server_unavailable}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      assert {:error, ^expected_connack} = Connector.init({:gen_tcp, ip, port}, connect)
      assert_receive {:server_received, ^connect}
    end

    test "bad user name or password", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :bad_user_name_or_password}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      assert {:error, ^expected_connack} = Connector.init({:gen_tcp, ip, port}, connect)
      assert_receive {:server_received, ^connect}
    end

    test "not authorized", context do
      client_id = context.client_id

      connect = %Package.Connect{client_id: client_id}
      expected_connack = %Package.Connack{status: {:refused, :not_authorized}}

      script = [{:receive, connect}, {:send, expected_connack}]
      {:ok, {ip, port}} = ScriptedMqttServer.enact(context.scripted_mqtt_server, script)

      assert {:error, ^expected_connack} = Connector.init({:gen_tcp, ip, port}, connect)
      assert_receive {:server_received, ^connect}
    end
  end
end

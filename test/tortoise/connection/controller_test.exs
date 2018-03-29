defmodule Tortoise.Connection.ControllerTest do
  use ExUnit.Case
  doctest Tortoise.Connection.Controller

  alias Tortoise.Connection.{Controller, Transmitter}
  alias Tortoise.Package

  defmodule TestDriver do
    # pass in the caller pid as the state so we can send messages back
    # to the test process that we can use for assertions
    @behaviour Tortoise.Driver

    defstruct pid: nil, publish_count: 0, received: []

    def init([caller]) when is_pid(caller) do
      {:ok, %__MODULE__{pid: caller}}
    end

    def on_publish(topic, message, %__MODULE__{} = state) do
      new_state = %__MODULE__{
        state
        | publish_count: state.publish_count + 1,
          received: [{topic, message} | state.received]
      }

      send(state.pid, new_state)
      {:ok, new_state}
    end

    def disconnect(_state) do
      :ok
    end
  end

  test "life cycle" do
    client_id = "hello"
    opts = valid_opts(client_id)
    assert {:ok, _} = Controller.start_link(opts)
    assert :ok = Controller.stop(client_id)
  end

  describe "publish" do
    test "receive a publish" do
      client_id = "receive a message"
      opts = valid_opts(client_id)
      assert {:ok, _} = Controller.start_link(opts)

      publish = %Package.Publish{
        identifier: nil,
        topic: "foo/bar/baz",
        payload: "how do you do?",
        qos: 0
      }

      assert :ok = Controller.handle_incoming(client_id, publish)
      payload = publish.payload
      assert_receive(%TestDriver{received: [{["foo", "bar", "baz"], ^payload} | _]})
    end

    # need to be able to update state in callback module between publishes
    test "updating state" do
      client_id = "updating state"
      opts = valid_opts(client_id)
      {:ok, _} = Controller.start_link(opts)

      publish = %Package.Publish{
        identifier: nil,
        topic: "foo/bar",
        payload: "how do you do?",
        qos: 0
      }

      :ok = Controller.handle_incoming(client_id, publish)
      assert_receive %TestDriver{publish_count: 1}
      :ok = Controller.handle_incoming(client_id, publish)
      assert_receive %TestDriver{publish_count: 2}
    end
  end

  describe "Ping Control Packets" do
    test "send a ping request" do
      client_id = "outgoing ping"
      opts = valid_opts(client_id)
      {:ok, _} = Controller.start_link(opts)
      {:ok, _} = Transmitter.start_link(opts)
      {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
      Transmitter.handle_socket(client_id, client_socket)

      # send a ping request to the server
      assert :ok = Transmitter.ping(client_id)
      # assert that the server receives a ping request package
      {:ok, package} = :gen_tcp.recv(server_socket, 0, 200)
      assert %Package.Pingreq{} = Package.decode(package)
      # the server will respond with an pingresp (ping response)
      Controller.handle_incoming(client_id, %Package.Pingresp{})
      :timer.sleep(200)
    end

    test "receive a ping request" do
      client_id = "incoming ping"
      opts = valid_opts(client_id)
      {:ok, _} = Controller.start_link(opts)
      {:ok, _} = Transmitter.start_link(opts)
      {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
      Transmitter.handle_socket(client_id, client_socket)

      # receiving a ping request to the server
      Controller.handle_incoming(client_id, %Package.Pingreq{})

      # assert that we send a ping response back to the server
      {:ok, package} = :gen_tcp.recv(server_socket, 0, 200)
      assert %Package.Pingresp{} = Package.decode(package)
    end
  end

  describe "Publish Control Packets with Quality of Service level 1" do
    test "incoming publish with qos 1" do
      client_id = "qos 1 publish"
      opts = valid_opts(client_id)
      {:ok, _} = Controller.start_link(opts)
      {:ok, _} = Transmitter.start_link(opts)
      {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
      Transmitter.handle_socket(client_id, client_socket)
      # receive a publish message with a qos of 1
      Controller.handle_incoming(client_id, %Package.Publish{
        identifier: 12312,
        topic: "a",
        payload: "b",
        qos: 1
      })

      # a puback message should get transmitted
      {:ok, package} = :gen_tcp.recv(server_socket, 0, 200)
      assert %Package.Puback{identifier: 12312} = Package.decode(package)
    end

    test "outgoing publish with qos 1" do
      client_id = "outgoing qos 1 publish"
      opts = valid_opts(client_id)
      {:ok, _} = Controller.start_link(opts)
      # setup a transmitter and hand it a socket we can make
      # assertions on
      {:ok, _} = Transmitter.start_link(opts)

      {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()

      Transmitter.handle_socket(client_id, client_socket)

      # send a publish qos 1 to the server, we will get a reference
      # (not the message id).
      publish =
        %{identifier: id} = %Package.Publish{
          identifier: Enum.random(0x0001..0xFFFF),
          topic: "a",
          qos: 1
        }

      assert {:ok, ref} = Transmitter.publish(client_id, publish)

      # assert that the server receives a publish package
      {:ok, package} = :gen_tcp.recv(server_socket, 0, 200)
      assert ^publish = Package.decode(package)
      # the server will send back an ack message
      Controller.handle_incoming(client_id, %Package.Puback{identifier: id})
      # the caller should get a message in its mailbox
      assert_receive {Tortoise, {{^client_id, ^ref}, :ok}}
    end

    test "outgoing publish with qos 1 sync call" do
      client_id = "sync outgoing qos 1"
      opts = valid_opts(client_id)
      {:ok, _} = Controller.start_link(opts)
      # setup a transmitter and hand it a socket we can make
      # assertions on
      {:ok, _} = Transmitter.start_link(opts)
      {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
      :ok = Transmitter.handle_socket(client_id, client_socket)

      # send a publish qos 1 to the server, we will get a reference
      # (not the message id).
      publish = %Package.Publish{
        identifier: 1,
        topic: "a",
        qos: 1
      }

      # setup a blocking call
      {caller, test_ref} = {self(), make_ref()}

      spawn_link(fn ->
        test_result = Transmitter.publish_sync(client_id, publish)
        send(caller, {:sync_call_result, test_ref, test_result})
      end)

      # assert that the server receives a publish package
      {:ok, package} = :gen_tcp.recv(server_socket, 0, 200)
      assert ^publish = Package.decode(package)
      # the server will send back an ack message
      Controller.handle_incoming(client_id, %Package.Puback{identifier: 1})
      # the blocking call should receive :ok when the message is acked
      assert_receive {:sync_call_result, ^test_ref, :ok}
    end
  end

  describe "Publish Quality of Service level 2" do
    test "incoming publish with qos 2" do
      client_id = "qos 2 publish"
      opts = valid_opts(client_id)
      {:ok, _} = Controller.start_link(opts)
      # setup a transmitter and hand it a socket we can make
      # assertions on
      {:ok, _} = Transmitter.start_link(opts)
      {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
      :ok = Transmitter.handle_socket(client_id, client_socket)

      # send in an publish message with a qos of 2
      Controller.handle_incoming(client_id, %Package.Publish{
        identifier: 12312,
        topic: "a",
        payload: "b",
        qos: 2
      })

      # assert that the sender receives a pubrec package
      {:ok, pubrec} = :gen_tcp.recv(server_socket, 0, 200)
      assert %Package.Pubrec{identifier: 12312} = Package.decode(pubrec)

      # the MQTT server will then respond with pubrel
      Controller.handle_incoming(client_id, %Package.Pubrel{identifier: 12312})
      # a pubcomp message should get transmitted
      {:ok, pubcomp} = :gen_tcp.recv(server_socket, 0, 200)
      assert %Package.Pubcomp{identifier: 12312} = Package.decode(pubcomp)
    end

    test "outgoing publish with qos 2" do
      client_id = "outgoing qos 2 publish"
      opts = valid_opts(client_id)
      {:ok, _} = Controller.start_link(opts)
      # setup a transmitter and hand it a socket we can make
      # assertions on
      {:ok, _} = Transmitter.start_link(opts)

      {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()

      Transmitter.handle_socket(client_id, client_socket)

      # send a publish qos 2 to the server, we will get a reference
      # (not the message id).
      id = 0x0001

      publish = %Package.Publish{
        identifier: id,
        topic: "foo",
        qos: 2
      }

      assert {:ok, ref} = Transmitter.publish(client_id, publish)

      # assert that the server receives a publish package
      {:ok, package} = :gen_tcp.recv(server_socket, 0, 200)
      assert ^publish = Package.decode(package)
      # the server will send back a publish received message
      Controller.handle_incoming(client_id, %Package.Pubrec{identifier: id})
      # send publish release (pubrel) to the server
      {:ok, package} = :gen_tcp.recv(server_socket, 0, 200)
      assert %Package.Pubrel{identifier: ^id} = Package.decode(package)
      # receive pubcomp
      Controller.handle_incoming(client_id, %Package.Pubcomp{identifier: id})
      # the caller should get a message in its mailbox
      assert_receive {Tortoise, {{^client_id, ^ref}, :ok}}
    end
  end

  # helpers
  defp valid_opts(client_id) do
    driver = %Tortoise.Driver{
      module: __MODULE__.TestDriver,
      initial_args: [self()]
    }

    [client_id: client_id, driver: driver]
  end
end

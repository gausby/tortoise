defmodule Tortoise.Connection.ControllerTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Connection.Controller

  alias Tortoise.Package
  alias Tortoise.Connection.{Controller, Inflight, Transmitter}

  defmodule TestDriver do
    @behaviour Tortoise.Driver

    defstruct pid: nil, client_id: nil, publish_count: 0, received: []

    def init([client_id, caller]) when is_pid(caller) do
      # We pass in the caller `pid` and keep it in the state so we can
      # send messages back to the test process, which will make it
      # possible to make assertions on the changes in the driver
      # callback module
      {:ok, %__MODULE__{pid: caller, client_id: client_id}}
    end

    def handle_message(topic, message, %__MODULE__{} = state) do
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

  # Setup ==============================================================
  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_controller(context) do
    driver = %Tortoise.Driver{
      module: __MODULE__.TestDriver,
      initial_args: [context.client_id, self()]
    }

    opts = [client_id: context.client_id, driver: driver]
    {:ok, pid} = Controller.start_link(opts)
    {:ok, %{controller_pid: pid}}
  end

  def setup_inflight(context) do
    opts = [client_id: context.client_id]
    {:ok, pid} = Inflight.start_link(opts)
    {:ok, %{inflight_pid: pid}}
  end

  def setup_transmitter(context) do
    opts = [client_id: context.client_id]
    {:ok, _} = Transmitter.start_link(opts)
    {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
    Transmitter.handle_socket(context.test, client_socket)

    {:ok, %{client: client_socket, server: server_socket}}
  end

  # tests --------------------------------------------------------------
  test "life cycle", context do
    driver = %Tortoise.Driver{
      module: __MODULE__.TestDriver,
      initial_args: [context.client_id, self()]
    }

    opts = [client_id: context.client_id, driver: driver]
    assert {:ok, pid} = Controller.start_link(opts)
    assert Process.alive?(pid)
    assert :ok = Controller.stop(context.client_id)
    refute Process.alive?(pid)
  end

  describe "Ping Control Packets" do
    setup [:setup_controller, :setup_transmitter]

    test "send a ping request", context do
      # send a ping request to the server
      assert {:ok, ping_ref} = Controller.ping(context.client_id)
      # assert that the server receives a ping request package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pingreq{} = Package.decode(package)
      # the server will respond with an pingresp (ping response)
      Controller.handle_incoming(context.client_id, %Package.Pingresp{})
      assert_receive {Tortoise, {:ping_response, ^ping_ref, _ping_time}}
    end

    test "receive a ping request", context do
      # receiving a ping request from the server
      Controller.handle_incoming(context.client_id, %Package.Pingreq{})

      # assert that we send a ping response back to the server
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pingresp{} = Package.decode(package)
    end

    test "ping request reports are sent in the correct order", context do
      # send two ping requests to the server
      assert {:ok, first_ping_ref} = Controller.ping(context.client_id)
      assert {:ok, second_ping_ref} = Controller.ping(context.client_id)

      # the controller should respond to ping requests in FIFO order
      Controller.handle_incoming(context.client_id, %Package.Pingresp{})
      assert_receive {Tortoise, {:ping_response, ^first_ping_ref, _}}
      Controller.handle_incoming(context.client_id, %Package.Pingresp{})
      assert_receive {Tortoise, {:ping_response, ^second_ping_ref, _}}
    end
  end

  describe "publish" do
    setup [:setup_controller]

    test "receive a publish", context do
      publish = %Package.Publish{
        topic: "foo/bar/baz",
        payload: "how do you do?",
        qos: 0
      }

      assert :ok = Controller.handle_incoming(context.client_id, publish)
      topic_list = String.split(publish.topic, "/")
      payload = publish.payload
      assert_receive(%TestDriver{received: [{^topic_list, ^payload} | _]})
    end

    test "update callback module state between publishes", context do
      publish = %Package.Publish{topic: "a", qos: 0}
      # Our callback module will increment a counter when it receives
      # a publish control packet
      :ok = Controller.handle_incoming(context.client_id, publish)
      assert_receive %TestDriver{publish_count: 1}
      :ok = Controller.handle_incoming(context.client_id, publish)
      assert_receive %TestDriver{publish_count: 2}
    end
  end

  describe "Publish Control Packets with Quality of Service level 1" do
    setup [:setup_controller, :setup_inflight, :setup_transmitter]

    test "incoming publish with qos 1", context do
      # receive a publish message with a qos of 1
      publish = %Package.Publish{identifier: 1, topic: "a", qos: 1}
      Controller.handle_incoming(context.client_id, publish)

      # a puback message should get transmitted
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Puback{identifier: 1} = Package.decode(package)
    end

    test "outgoing publish with qos 1", context do
      client_id = context.client_id
      publish = %Package.Publish{identifier: 1, topic: "a", qos: 1}
      # we will get a reference (not the message id).
      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})

      # assert that the server receives a publish package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert ^publish = Package.decode(package)
      # the server will send back an ack message
      Controller.handle_incoming(client_id, %Package.Puback{identifier: 1})
      # the caller should get a message in its mailbox
      assert_receive {Tortoise, {{^client_id, ^ref}, :ok}}
    end

    test "outgoing publish with qos 1 sync call", context do
      client_id = context.client_id
      publish = %Package.Publish{identifier: 1, topic: "a", qos: 1}

      # setup a blocking call
      {caller, test_ref} = {self(), make_ref()}

      spawn_link(fn ->
        test_result = Inflight.track_sync(client_id, {:outgoing, publish})
        send(caller, {:sync_call_result, test_ref, test_result})
      end)

      # assert that the server receives a publish package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert ^publish = Package.decode(package)
      # the server will send back an ack message
      Controller.handle_incoming(client_id, %Package.Puback{identifier: 1})
      # the blocking call should receive :ok when the message is acked
      assert_receive {:sync_call_result, ^test_ref, :ok}
    end
  end

  describe "Publish Quality of Service level 2" do
    setup [:setup_controller, :setup_inflight, :setup_transmitter]

    test "incoming publish with qos 2", context do
      client_id = context.client_id
      # send in an publish message with a QoS of 2
      publish = %Package.Publish{identifier: 1, topic: "a", qos: 2}
      Controller.handle_incoming(client_id, publish)

      # assert that the sender receives a pubrec package
      {:ok, pubrec} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pubrec{identifier: 1} = Package.decode(pubrec)
      # the MQTT server will then respond with pubrel
      Controller.handle_incoming(client_id, %Package.Pubrel{identifier: 1})
      # a pubcomp message should get transmitted
      {:ok, pubcomp} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pubcomp{identifier: 1} = Package.decode(pubcomp)
    end

    test "outgoing publish with qos 2", context do
      client_id = context.client_id
      publish = %Package.Publish{identifier: 1, topic: "a", qos: 2}

      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, publish})

      # assert that the server receives a publish package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert ^publish = Package.decode(package)
      # the server will send back a publish received message
      Controller.handle_incoming(client_id, %Package.Pubrec{identifier: 1})
      # we should send a publish release (pubrel) to the server
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pubrel{identifier: 1} = Package.decode(package)
      # receive pubcomp
      Controller.handle_incoming(client_id, %Package.Pubcomp{identifier: 1})
      # the caller should get a message in its mailbox
      assert_receive {Tortoise, {{^client_id, ^ref}, :ok}}
    end
  end
end

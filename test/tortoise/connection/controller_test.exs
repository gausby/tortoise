defmodule Tortoise311.Connection.ControllerTest do
  use ExUnit.Case
  doctest Tortoise311.Connection.Controller

  alias Tortoise311.Package
  alias Tortoise311.Connection.{Controller, Inflight}

  import ExUnit.CaptureLog

  defmodule TestHandler do
    use Tortoise311.Handler

    defstruct pid: nil,
              client_id: nil,
              status: nil,
              publish_count: 0,
              received: [],
              subscriptions: []

    def init([client_id, caller]) when is_pid(caller) do
      # We pass in the caller `pid` and keep it in the state so we can
      # send messages back to the test process, which will make it
      # possible to make assertions on the changes in the handler
      # callback module
      {:ok, %__MODULE__{pid: caller, client_id: client_id}}
    end

    def connection(status, state) do
      new_state = %__MODULE__{state | status: status}
      send(state.pid, new_state)
      {:ok, new_state}
    end

    def subscription(:up, topic_filter, state) do
      new_state = %__MODULE__{
        state
        | subscriptions: [{topic_filter, :ok} | state.subscriptions]
      }

      send(state.pid, new_state)
      {:ok, new_state}
    end

    def subscription(:down, topic_filter, state) do
      new_state = %__MODULE__{
        state
        | subscriptions:
            Enum.reject(state.subscriptions, fn {topic, _} -> topic == topic_filter end)
      }

      send(state.pid, new_state)
      {:ok, new_state}
    end

    def subscription({:warn, warning}, topic_filter, state) do
      new_state = %__MODULE__{
        state
        | subscriptions: [{topic_filter, warning} | state.subscriptions]
      }

      send(state.pid, new_state)
      {:ok, new_state}
    end

    def subscription({:error, reason}, topic_filter, state) do
      send(state.pid, {:subscription_error, {topic_filter, reason}})
      {:ok, state}
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

    def terminate(reason, state) do
      send(state.pid, {:terminating, reason})
      :ok
    end
  end

  # Setup ==============================================================
  setup context do
    {:ok, %{client_id: context.test}}
  end

  def setup_controller(context) do
    handler = %Tortoise311.Handler{
      module: __MODULE__.TestHandler,
      initial_args: [context.client_id, self()]
    }

    opts = [client_id: context.client_id, handler: handler]
    {:ok, pid} = Controller.start_link(opts)
    {:ok, %{controller_pid: pid}}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise311.Integration.TestTCPTunnel.new()
    name = Tortoise311.Connection.via_name(context.client_id)
    :ok = Tortoise311.Registry.put_meta(name, {Tortoise311.Transport.Tcp, client_socket})
    {:ok, %{client: client_socket, server: server_socket}}
  end

  def setup_inflight(context) do
    opts = [client_id: context.client_id]
    {:ok, pid} = Inflight.start_link(opts)
    {:ok, %{inflight_pid: pid}}
  end

  # tests --------------------------------------------------------------
  test "life cycle", context do
    handler = %Tortoise311.Handler{
      module: __MODULE__.TestHandler,
      initial_args: [context.client_id, self()]
    }

    opts = [client_id: context.client_id, handler: handler]
    assert {:ok, pid} = Controller.start_link(opts)
    assert Process.alive?(pid)
    assert :ok = Controller.stop(context.client_id)
    refute Process.alive?(pid)
    assert_receive {:terminating, :normal}
  end

  describe "Connection callback" do
    setup [:setup_controller]

    test "Callback is triggered on connection status change", context do
      # tell the controller that we are up
      :ok = Tortoise311.Events.dispatch(context.client_id, :status, :up)
      assert_receive(%TestHandler{status: :up})
      # switch to offline
      :ok = Tortoise311.Events.dispatch(context.client_id, :status, :down)
      assert_receive(%TestHandler{status: :down})
      # ... and back up
      :ok = Tortoise311.Events.dispatch(context.client_id, :status, :up)
      assert_receive(%TestHandler{status: :up})
    end
  end

  describe "Connection Control Packets" do
    setup [:setup_controller]

    test "receiving a connect from the server is a protocol violation",
         %{controller_pid: pid} = context do
      Process.flag(:trap_exit, true)
      # receiving a connect from the server is a protocol violation
      connect = %Package.Connect{client_id: "foo"}
      Controller.handle_incoming(context.client_id, connect)

      assert_receive {:EXIT, ^pid,
                      {:protocol_violation, {:unexpected_package_from_remote, ^connect}}}
    end

    test "receiving a connack at this point is a protocol violation",
         %{controller_pid: pid} = context do
      Process.flag(:trap_exit, true)
      # receiving a connack from the server *after* the connection has
      # been acknowledged is a protocol violation
      connack = %Package.Connack{status: :accepted}
      Controller.handle_incoming(context.client_id, connack)

      assert_receive {:EXIT, ^pid,
                      {:protocol_violation, {:unexpected_package_from_remote, ^connack}}}
    end

    test "receiving a disconnect from the server is a protocol violation",
         %{controller_pid: pid} = context do
      Process.flag(:trap_exit, true)
      # receiving a disconnect request from the server is a (3.1.1)
      # protocol violation
      disconnect = %Package.Disconnect{}
      Controller.handle_incoming(context.client_id, disconnect)

      assert_receive {:EXIT, ^pid,
                      {:protocol_violation, {:unexpected_package_from_remote, ^disconnect}}}
    end
  end

  describe "Ping Control Packets" do
    setup [:setup_connection, :setup_controller]

    test "send a ping request", context do
      # send a ping request to the server
      assert {:ok, ping_ref} = Controller.ping(context.client_id)
      # assert that the server receives a ping request package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pingreq{} = Package.decode(package)
      # the server will respond with an pingresp (ping response)
      Controller.handle_incoming(context.client_id, %Package.Pingresp{})
      assert_receive {Tortoise311, {:ping_response, ^ping_ref, _ping_time}}
    end

    test "send a sync ping request", context do
      # send a ping request to the server
      parent = self()

      spawn_link(fn ->
        {:ok, time} = Controller.ping_sync(context.client_id)
        send(parent, {:ping_result, time})
      end)

      # assert that the server receives a ping request package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pingreq{} = Package.decode(package)
      # the server will respond with an pingresp (ping response)
      Controller.handle_incoming(context.client_id, %Package.Pingresp{})
      assert_receive {:ping_result, _time}
    end

    test "receiving a ping request", %{controller_pid: pid} = context do
      Process.flag(:trap_exit, true)
      # receiving a ping request from the server is a protocol violation
      pingreq = %Package.Pingreq{}
      Controller.handle_incoming(context.client_id, pingreq)

      assert_receive {:EXIT, ^pid,
                      {:protocol_violation, {:unexpected_package_from_remote, ^pingreq}}}
    end

    test "ping request reports are sent in the correct order", context do
      # send two ping requests to the server
      assert {:ok, first_ping_ref} = Controller.ping(context.client_id)
      assert {:ok, second_ping_ref} = Controller.ping(context.client_id)

      # the controller should respond to ping requests in FIFO order
      Controller.handle_incoming(context.client_id, %Package.Pingresp{})
      assert_receive {Tortoise311, {:ping_response, ^first_ping_ref, _}}
      Controller.handle_incoming(context.client_id, %Package.Pingresp{})
      assert_receive {Tortoise311, {:ping_response, ^second_ping_ref, _}}
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
      assert_receive(%TestHandler{received: [{^topic_list, ^payload} | _]})
    end

    test "update callback module state between publishes", context do
      publish = %Package.Publish{topic: "a", qos: 0}
      # Our callback module will increment a counter when it receives
      # a publish control packet
      :ok = Controller.handle_incoming(context.client_id, publish)
      assert_receive %TestHandler{publish_count: 1}
      :ok = Controller.handle_incoming(context.client_id, publish)
      assert_receive %TestHandler{publish_count: 2}
    end
  end

  describe "Publish Control Packets with Quality of Service level 1" do
    setup [:setup_connection, :setup_controller, :setup_inflight]

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
      assert_receive {{Tortoise311, ^client_id}, ^ref, :ok}
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
    setup [:setup_connection, :setup_controller, :setup_inflight]

    test "incoming publish with qos 2", context do
      client_id = context.client_id
      # send in an publish message with a QoS of 2
      publish = %Package.Publish{identifier: 1, topic: "a", qos: 2}
      :ok = Controller.handle_incoming(client_id, publish)
      # test sending in a duplicate publish
      :ok = Controller.handle_incoming(client_id, %Package.Publish{publish | dup: true})

      # assert that the sender receives a pubrec package
      {:ok, pubrec} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pubrec{identifier: 1} = Package.decode(pubrec)

      # the publish should get onwarded to the handler
      assert_receive %TestHandler{publish_count: 1, received: [{["a"], nil}]}

      # the MQTT server will then respond with pubrel
      Controller.handle_incoming(client_id, %Package.Pubrel{identifier: 1})
      # a pubcomp message should get transmitted
      {:ok, pubcomp} = :gen_tcp.recv(context.server, 0, 200)

      assert %Package.Pubcomp{identifier: 1} = Package.decode(pubcomp)

      # the publish should only get onwareded once
      refute_receive %TestHandler{publish_count: 2}
    end

    test "incoming publish with qos 2 (first message dup)", context do
      # send in an publish with dup set to true should succeed if the
      # id is unknown.
      client_id = context.client_id
      # send in an publish message with a QoS of 2
      publish = %Package.Publish{identifier: 1, topic: "a", qos: 2, dup: true}
      :ok = Controller.handle_incoming(client_id, publish)

      # assert that the sender receives a pubrec package
      {:ok, pubrec} = :gen_tcp.recv(context.server, 0, 200)
      assert %Package.Pubrec{identifier: 1} = Package.decode(pubrec)

      # the MQTT server will then respond with pubrel
      Controller.handle_incoming(client_id, %Package.Pubrel{identifier: 1})
      # a pubcomp message should get transmitted
      {:ok, pubcomp} = :gen_tcp.recv(context.server, 0, 200)

      assert %Package.Pubcomp{identifier: 1} = Package.decode(pubcomp)

      # the publish should get onwarded to the handler
      assert_receive %TestHandler{publish_count: 1, received: [{["a"], nil}]}
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
      assert_receive {{Tortoise311, ^client_id}, ^ref, :ok}
    end
  end

  describe "Subscription" do
    setup [:setup_connection, :setup_controller, :setup_inflight]

    test "Subscribe to multiple topics", context do
      client_id = context.client_id

      subscribe = %Package.Subscribe{
        identifier: 1,
        topics: [{"foo", 0}, {"bar", 1}, {"baz", 2}]
      }

      suback = %Package.Suback{identifier: 1, acks: [{:ok, 0}, {:ok, 1}, {:ok, 2}]}

      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, subscribe})

      # assert that the server receives a subscribe package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert ^subscribe = Package.decode(package)
      # the server will send back a subscription acknowledgement message
      :ok = Controller.handle_incoming(client_id, suback)

      assert_receive {{Tortoise311, ^client_id}, ^ref, _}
      # the client callback module should get the subscribe notifications in order
      assert_receive %TestHandler{subscriptions: [{"foo", :ok}]}
      assert_receive %TestHandler{subscriptions: [{"bar", :ok} | _]}
      assert_receive %TestHandler{subscriptions: [{"baz", :ok} | _]}

      # unsubscribe from a topic
      unsubscribe = %Package.Unsubscribe{identifier: 2, topics: ["foo", "baz"]}
      unsuback = %Package.Unsuback{identifier: 2}
      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, unsubscribe})
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert ^unsubscribe = Package.decode(package)
      :ok = Controller.handle_incoming(client_id, unsuback)
      assert_receive {{Tortoise311, ^client_id}, ^ref, _}

      # the client callback module should remove the subscriptions in order
      assert_receive %TestHandler{subscriptions: [{"baz", :ok}, {"bar", :ok}]}
      assert_receive %TestHandler{subscriptions: [{"bar", :ok}]}
    end

    test "Subscribe to a topic that return different QoS than requested", context do
      client_id = context.client_id

      subscribe = %Package.Subscribe{
        identifier: 1,
        topics: [{"foo", 2}]
      }

      suback = %Package.Suback{identifier: 1, acks: [{:ok, 0}]}

      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, subscribe})

      # assert that the server receives a subscribe package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert ^subscribe = Package.decode(package)
      # the server will send back a subscription acknowledgement message
      :ok = Controller.handle_incoming(client_id, suback)

      assert_receive {{Tortoise311, ^client_id}, ^ref, _}
      # the client callback module should get the subscribe notifications in order
      assert_receive %TestHandler{subscriptions: [{"foo", [requested: 2, accepted: 0]}]}

      # unsubscribe from a topic
      unsubscribe = %Package.Unsubscribe{identifier: 2, topics: ["foo"]}
      unsuback = %Package.Unsuback{identifier: 2}
      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, unsubscribe})
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert ^unsubscribe = Package.decode(package)
      :ok = Controller.handle_incoming(client_id, unsuback)
      assert_receive {{Tortoise311, ^client_id}, ^ref, _}

      # the client callback module should remove the subscription
      assert_receive %TestHandler{subscriptions: []}
    end

    test "Subscribe to a topic resulting in an error", context do
      client_id = context.client_id

      subscribe = %Package.Subscribe{
        identifier: 1,
        topics: [{"foo", 1}]
      }

      suback = %Package.Suback{identifier: 1, acks: [{:error, :access_denied}]}

      assert {:ok, ref} = Inflight.track(client_id, {:outgoing, subscribe})

      # assert that the server receives a subscribe package
      {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
      assert ^subscribe = Package.decode(package)
      # the server will send back a subscription acknowledgement message
      :ok = Controller.handle_incoming(client_id, suback)

      assert_receive {{Tortoise311, ^client_id}, ^ref, _}
      # the callback module should get the error
      assert_receive {:subscription_error, {"foo", :access_denied}}
    end

    test "Receiving a subscribe package is a protocol violation",
         %{controller_pid: pid} = context do
      Process.flag(:trap_exit, true)
      # receiving a subscribe from the server is a protocol violation
      subscribe = %Package.Subscribe{
        identifier: 1,
        topics: [{"foo/bar", 0}]
      }

      Controller.handle_incoming(context.client_id, subscribe)

      assert_receive {:EXIT, ^pid,
                      {:protocol_violation, {:unexpected_package_from_remote, ^subscribe}}}
    end

    test "Receiving an unsubscribe package is a protocol violation",
         %{controller_pid: pid} = context do
      Process.flag(:trap_exit, true)
      # receiving an unsubscribe from the server is a protocol violation
      unsubscribe = %Package.Unsubscribe{
        identifier: 1,
        topics: ["foo/bar"]
      }

      Controller.handle_incoming(context.client_id, unsubscribe)

      assert_receive {:EXIT, ^pid,
                      {:protocol_violation, {:unexpected_package_from_remote, ^unsubscribe}}}
    end
  end

  describe "next actions" do
    setup [:setup_controller]

    test "subscribe action", context do
      client_id = context.client_id
      next_action = {:subscribe, "foo/bar", qos: 0}
      send(context.controller_pid, {:next_action, next_action})
      %{awaiting: awaiting} = Controller.info(client_id)
      assert [{ref, ^next_action}] = Map.to_list(awaiting)
      response = {{Tortoise311, client_id}, ref, :ok}
      send(context.controller_pid, response)
      %{awaiting: awaiting} = Controller.info(client_id)
      assert [] = Map.to_list(awaiting)
    end

    test "unsubscribe action", context do
      client_id = context.client_id
      next_action = {:unsubscribe, "foo/bar"}
      send(context.controller_pid, {:next_action, next_action})
      %{awaiting: awaiting} = Controller.info(client_id)
      assert [{ref, ^next_action}] = Map.to_list(awaiting)
      response = {{Tortoise311, client_id}, ref, :ok}
      send(context.controller_pid, response)
      %{awaiting: awaiting} = Controller.info(client_id)
      assert [] = Map.to_list(awaiting)
    end

    test "receiving unknown async ref", context do
      client_id = context.client_id
      ref = make_ref()

      assert capture_log(fn ->
               send(context.controller_pid, {{Tortoise311, client_id}, ref, :ok})
               :timer.sleep(100)
             end) =~ "Unexpected"

      %{awaiting: awaiting} = Controller.info(client_id)
      assert [] = Map.to_list(awaiting)
    end
  end
end

# defmodule Tortoise.Connection.ControllerTest do
#   use ExUnit.Case
#   doctest Tortoise.Connection.Controller

#   alias Tortoise.Package
#   alias Tortoise.Connection.{Controller, Inflight}

#   import ExUnit.CaptureLog

#   defmodule TestHandler do
#     use Tortoise.Handler

#     defstruct pid: nil,
#               client_id: nil,
#               status: nil,
#               publish_count: 0,
#               received: [],
#               subscriptions: []

#     def init([client_id, caller]) when is_pid(caller) do
#       # We pass in the caller `pid` and keep it in the state so we can
#       # send messages back to the test process, which will make it
#       # possible to make assertions on the changes in the handler
#       # callback module
#       {:ok, %__MODULE__{pid: caller, client_id: client_id}}
#     end

#     def connection(status, state) do
#       new_state = %__MODULE__{state | status: status}
#       send(state.pid, new_state)
#       {:ok, new_state}
#     end

#     def subscription(:up, topic_filter, state) do
#       new_state = %__MODULE__{
#         state
#         | subscriptions: [{topic_filter, :ok} | state.subscriptions]
#       }

#       send(state.pid, new_state)
#       {:ok, new_state}
#     end

#     def subscription(:down, topic_filter, state) do
#       new_state = %__MODULE__{
#         state
#         | subscriptions:
#             Enum.reject(state.subscriptions, fn {topic, _} -> topic == topic_filter end)
#       }

#       send(state.pid, new_state)
#       {:ok, new_state}
#     end

#     def subscription({:warn, warning}, topic_filter, state) do
#       new_state = %__MODULE__{
#         state
#         | subscriptions: [{topic_filter, warning} | state.subscriptions]
#       }

#       send(state.pid, new_state)
#       {:ok, new_state}
#     end

#     def subscription({:error, reason}, topic_filter, state) do
#       send(state.pid, {:subscription_error, {topic_filter, reason}})
#       {:ok, state}
#     end

#     def handle_message(topic, message, %__MODULE__{} = state) do
#       new_state = %__MODULE__{
#         state
#         | publish_count: state.publish_count + 1,
#           received: [{topic, message} | state.received]
#       }

#       send(state.pid, new_state)
#       {:ok, new_state}
#     end

#     def terminate(reason, state) do
#       send(state.pid, {:terminating, reason})
#       :ok
#     end
#   end

#   # Setup ==============================================================
#   setup context do
#     {:ok, %{client_id: context.test}}
#   end

#   def setup_controller(context) do
#     handler = %Tortoise.Handler{
#       module: __MODULE__.TestHandler,
#       initial_args: [context.client_id, self()]
#     }

#     opts = [client_id: context.client_id, handler: handler]
#     {:ok, pid} = Controller.start_link(opts)
#     {:ok, %{controller_pid: pid}}
#   end

#   def setup_connection(context) do
#     {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
#     name = Tortoise.Connection.via_name(context.client_id)
#     :ok = Tortoise.Registry.put_meta(name, {Tortoise.Transport.Tcp, client_socket})
#     {:ok, %{client: client_socket, server: server_socket}}
#   end

#   def setup_inflight(context) do
#     opts = [client_id: context.client_id, parent: self()]
#     {:ok, pid} = Inflight.start_link(opts)
#     {:ok, %{inflight_pid: pid}}
#   end

#   # tests --------------------------------------------------------------
#   describe "publish" do
#     setup [:setup_controller]

#     test "update callback module state between publishes", context do
#       publish = %Package.Publish{topic: "a", qos: 0}
#       # Our callback module will increment a counter when it receives
#       # a publish control packet
#       :ok = Controller.handle_incoming(context.client_id, publish)
#       assert_receive %TestHandler{publish_count: 1}
#       :ok = Controller.handle_incoming(context.client_id, publish)
#       assert_receive %TestHandler{publish_count: 2}
#     end
#   end

#   describe "Subscription" do
#     setup [:setup_connection, :setup_controller, :setup_inflight]

#     test "Subscribe to a topic that return different QoS than requested", context do
#       client_id = context.client_id

#       subscribe = %Package.Subscribe{
#         identifier: 1,
#         topics: [{"foo", 2}]
#       }

#       suback = %Package.Suback{identifier: 1, acks: [{:ok, 0}]}

#       assert {:ok, ref} = Inflight.track(client_id, {:outgoing, subscribe})

#       # assert that the server receives a subscribe package
#       {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
#       assert ^subscribe = Package.decode(package)
#       # the server will send back a subscription acknowledgement message
#       :ok = Controller.handle_incoming(client_id, suback)

#       assert_receive {{Tortoise, ^client_id}, ^ref, _}
#       # the client callback module should get the subscribe notifications in order
#       assert_receive %TestHandler{subscriptions: [{"foo", [requested: 2, accepted: 0]}]}

#       # unsubscribe from a topic
#       unsubscribe = %Package.Unsubscribe{identifier: 2, topics: ["foo"]}
#       unsuback = %Package.Unsuback{identifier: 2}
#       assert {:ok, ref} = Inflight.track(client_id, {:outgoing, unsubscribe})
#       {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
#       assert ^unsubscribe = Package.decode(package)
#       :ok = Controller.handle_incoming(client_id, unsuback)
#       assert_receive {{Tortoise, ^client_id}, ^ref, _}

#       # the client callback module should remove the subscription
#       assert_receive %TestHandler{subscriptions: []}
#     end

#     test "Subscribe to a topic resulting in an error", context do
#       client_id = context.client_id

#       subscribe = %Package.Subscribe{
#         identifier: 1,
#         topics: [{"foo", 1}]
#       }

#       suback = %Package.Suback{identifier: 1, acks: [{:error, :access_denied}]}

#       assert {:ok, ref} = Inflight.track(client_id, {:outgoing, subscribe})

#       # assert that the server receives a subscribe package
#       {:ok, package} = :gen_tcp.recv(context.server, 0, 200)
#       assert ^subscribe = Package.decode(package)
#       # the server will send back a subscription acknowledgement message
#       :ok = Controller.handle_incoming(client_id, suback)

#       assert_receive {{Tortoise, ^client_id}, ^ref, _}
#       # the callback module should get the error
#       assert_receive {:subscription_error, {"foo", :access_denied}}
#     end
#   end

#   describe "next actions" do
#     setup [:setup_controller]

#     test "subscribe action", context do
#       client_id = context.client_id
#       next_action = {:subscribe, "foo/bar", qos: 0}
#       send(context.controller_pid, {:next_action, next_action})
#       %{awaiting: awaiting} = Controller.info(client_id)
#       assert [{ref, ^next_action}] = Map.to_list(awaiting)
#       response = {{Tortoise, client_id}, ref, :ok}
#       send(context.controller_pid, response)
#       %{awaiting: awaiting} = Controller.info(client_id)
#       assert [] = Map.to_list(awaiting)
#     end

#     test "unsubscribe action", context do
#       client_id = context.client_id
#       next_action = {:unsubscribe, "foo/bar"}
#       send(context.controller_pid, {:next_action, next_action})
#       %{awaiting: awaiting} = Controller.info(client_id)
#       assert [{ref, ^next_action}] = Map.to_list(awaiting)
#       response = {{Tortoise, client_id}, ref, :ok}
#       send(context.controller_pid, response)
#       %{awaiting: awaiting} = Controller.info(client_id)
#       assert [] = Map.to_list(awaiting)
#     end

#     test "receiving unknown async ref", context do
#       client_id = context.client_id
#       ref = make_ref()

#       assert capture_log(fn ->
#                send(context.controller_pid, {{Tortoise, client_id}, ref, :ok})
#                :timer.sleep(100)
#              end) =~ "Unexpected"

#       %{awaiting: awaiting} = Controller.info(client_id)
#       assert [] = Map.to_list(awaiting)
#     end
#   end
# end

defmodule Tortoise.PipeTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Pipe

  alias Tortoise.{Pipe, Package}

  setup context do
    {:ok, %{client_id: context.test}}
  end

  # def setup_inflight(context) do
  #   opts = [client_id: context.client_id, parent: self()]
  #   {:ok, inflight_pid} = Inflight.start_link(opts)
  #   :ok = Inflight.update_connection(inflight_pid, context.connection)
  #   {:ok, %{inflight_pid: inflight_pid}}
  # end

  def setup_registry(context) do
    key = Tortoise.Registry.via_name(Tortoise.Connection, context.client_id)
    Tortoise.Registry.put_meta(key, :connecting)
    {:ok, context}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise.Integration.TestTCPTunnel.new()
    connection = {Tortoise.Transport.Tcp, client_socket}
    key = Tortoise.Registry.via_name(Tortoise.Connection, context.client_id)
    Tortoise.Registry.put_meta(key, connection)
    {:ok, %{client: client_socket, server: server_socket, connection: connection}}
  end

  # update the context during a test run
  def run_setup(context, setup) when is_atom(setup) do
    context_update =
      case apply(__MODULE__, setup, [context]) do
        {:ok, update} -> update
        [{_, _} | _] = update -> update
        %{} = update -> update
      end

    Enum.into(context_update, context)
  end

  describe "new/2" do
    setup [:setup_registry]

    @tag skip: true
    test "generating a pipe when the connection is up", context do
      context = run_setup(context, :setup_connection)
      assert %Pipe{} = Pipe.new(context.client_id)
    end

    @tag skip: true
    test "generating a pipe while the connection is in connecting state", context do
      parent = self()
      client_id = context.client_id

      client =
        spawn_link(fn ->
          result = Pipe.new(client_id, timeout: 1000)
          send(parent, {:result, result})
        end)

      # sleep a bit, open a socket and reply to the client
      :timer.sleep(50)
      context = run_setup(context, :setup_connection)
      send(client, {{Tortoise, client_id}, :connection, {Tortoise.Transport.Tcp, context.client}})
      socket = context.client
      assert_receive {:result, %Pipe{client_id: ^client_id, socket: ^socket}}
    end
  end

  describe "publish/4" do
    setup [:setup_registry, :setup_connection]

    @tag skip: true
    test "publish a message", context do
      pipe = Pipe.new(context.test)
      topic = "foo/bar"
      payload = "my message"

      assert %Pipe{} = Pipe.publish(pipe, topic, payload)
      {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{topic: ^topic, payload: ^payload} = Package.decode(package)
    end

    @tag skip: true
    test "replace pipe during a publish if the socket is closed (active:false)", context do
      client_id = context.client_id
      parent = self()
      publish = %Package.Publish{topic: "foo"}

      subscriber =
        spawn_link(fn ->
          pipe = %Pipe{} = Pipe.new(client_id, timeout: 500)
          send(parent, {:subscriber_pipe, pipe})
          pipe = Pipe.publish(pipe, "foo")
          # Now the parent will close the socket belonging to the pipe
          # and start a new one. The next publish will get the newly
          # created socket when it attempt to publish.
          receive do
            :retry_publish ->
              # this publish should receive the new pipe
              pipe = %Pipe{} = Pipe.publish(pipe, "foo")
              send(parent, {:subscriber_pipe, pipe})
          end
        end)

      assert_receive {:subscriber_pipe, %Pipe{socket: original_socket}}
      {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert Package.decode(package) == publish
      :ok = :gen_tcp.close(context.client)
      context = run_setup(context, :setup_registry)

      send(subscriber, :retry_publish)
      :timer.sleep(40)
      context = run_setup(context, :setup_connection)
      connection = {Tortoise.Transport.Tcp, context.client}
      send(subscriber, {{Tortoise, client_id}, :connection, connection})

      {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert Package.decode(package) == publish
      assert_receive {:subscriber_pipe, %Pipe{socket: new_socket}}
      # the new socket should be different than the original socket
      refute new_socket == original_socket
    end
  end

  describe "await/1" do
    setup [:setup_registry, :setup_connection]

    @tag skip: true
    test "awaiting an empty pending list should complete instantly", context do
      pipe = Pipe.new(context.client_id)
      {:ok, %Pipe{pending: []}} = Pipe.await(pipe)
    end

    @tag skip: true
    test "error with a timeout if given timeout is reached", context do
      pipe = Pipe.new(context.client_id)
      pipe = Pipe.publish(pipe, "foo/bar", nil, qos: 1)
      {:error, :timeout} = Pipe.await(pipe, 20)
    end

    @tag skip: true
    test "block until pending packages has been acknowledged", context do
      client_id = context.client_id
      parent = self()

      child =
        spawn_link(fn ->
          pipe = %Pipe{} = Pipe.new(client_id, timeout: 500)
          pipe = %Pipe{} = Pipe.publish(pipe, "foo/bar", nil, qos: 1)

          receive do
            :continue ->
              pipe = %Pipe{} = Pipe.publish(pipe, "foo/baz", nil, qos: 2)
              result = Pipe.await(pipe, 500)
              send(parent, {:result, result})
          end
        end)

      # receive the QoS=1 publish so we can get the id and acknowledge it
      {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{identifier: id} = Package.decode(package)
      # Inflight.update(client_id, {:received, %Package.Puback{identifier: id}})

      send(child, :continue)
      # receive and acknowledge the QoS=2 publish
      {:ok, package} = :gen_tcp.recv(context.server, 0, 500)
      assert %Package.Publish{identifier: id} = Package.decode(package)
      # Inflight.update(client_id, {:received, %Package.Pubrec{identifier: id}})
      # Inflight.update(client_id, {:received, %Package.Pubcomp{identifier: id}})

      # both messages should be acknowledged by now
      assert_receive {:result, result}
      assert {:ok, %{pending: []}} = result
    end
  end

  # describe "publish/3" do
  #   # test "pipe", context do
  #   #   # is this actually smart? or am i abusing "into" here?
  #   #   [
  #   #     %Package.Publish{topic: "hello", payload: "foo"},
  #   #     %Package.Publish{topic: "hello2", payload: "bar"},
  #   #     %Package.Publish{topic: "hello3", payload: "baz"}
  #   #   ]
  #   #   |> Enum.into(%Pipe{client_id: context.client_id, socket: context.client})
  #   # end
  # end
end

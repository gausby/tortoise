defmodule Tortoise.PipeTest do
  use ExUnit.Case
  doctest Tortoise.Pipe

  alias Tortoise.{Pipe, Package}
  alias Tortoise.Connection.Transmitter

  def setup_transmitter(context) do
    opts = [client_id: context.test]
    {:ok, pid} = Transmitter.start_link(opts)
    {:ok, %{transmitter_pid: pid}}
  end

  def setup_connection(context) do
    {:ok, client_socket, server_socket} = Tortoise.TestTCPTunnel.new()
    :ok = Transmitter.handle_socket(context.test, client_socket)
    {:ok, %{client: client_socket, server: server_socket}}
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
    setup [:setup_transmitter]

    test "generate a pipe when transmitter is online", context do
      context = run_setup(context, :setup_connection)
      assert %Pipe{} = Pipe.new(context.test)
    end

    test "generate a pipe when transmitter is offline", context do
      parent = self()
      client_id = context.test

      spawn_link(fn ->
        result = Pipe.new(client_id)
        send(parent, {:result, result})
      end)

      :timer.sleep(200)
      _ = run_setup(context, :setup_connection)
      assert_receive {:result, %Pipe{client_id: ^client_id}}
    end
  end

  describe "publish/4" do
    setup [:setup_transmitter, :setup_connection]

    test "publish a message", context do
      pipe = Pipe.new(context.test)
      topic = "foo/bar"
      payload = "my message"

      assert %Pipe{} = Pipe.publish(pipe, topic, payload)
      {:ok, package} = :gen_tcp.recv(context.server, 0)
      assert %Package.Publish{topic: ^topic, payload: ^payload} = Package.decode(package)
    end

    test "replace pipe during a publish if the socket is closed (active:false)", context do
      client_id = context.test
      parent = self()
      publish = %Package.Publish{topic: "foo"}

      subscriber =
        spawn_link(fn ->
          pipe = Pipe.new(client_id)
          send(parent, {:subscriber_pipe, pipe})
          pipe = Pipe.publish(pipe, "foo")
          # Now the parent will close the socket belonging to the pipe
          # and start a new one. The next publish will get the newly
          # created socket when it attempt to publish.
          receive do
            :retry_publish ->
              # this publish should receive the new pipe
              pipe = Pipe.publish(pipe, "foo")
              send(parent, {:subscriber_pipe, pipe})
          end
        end)

      assert_receive {:subscriber_pipe, %Pipe{socket: original_socket}}
      {:ok, package} = :gen_tcp.recv(context.server, 0)
      assert Package.decode(package) == publish
      :ok = :gen_tcp.close(context.client)

      send(subscriber, :retry_publish)
      context = run_setup(context, :setup_connection)

      {:ok, package} = :gen_tcp.recv(context.server, 0)
      assert Package.decode(package) == publish
      assert_receive {:subscriber_pipe, %Pipe{socket: new_socket}}
      # the new socket should be different than the original socket
      refute new_socket == original_socket
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

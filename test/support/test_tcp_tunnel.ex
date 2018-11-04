defmodule Tortoise.Integration.TestTCPTunnel do
  @moduledoc """
  Create a TCP-tunnel making it possible to use :gen_tcp.send/2-3 to
  send to the client_socket and assert on the received data on the
  server_socket.

  This work for our Inflight-module which is handled a TCP-socket
  from the Receiver.
  """
  use GenServer

  defstruct [:socket, :ip, :port]

  # Client API
  def start_link() do
    initial_state = %__MODULE__{}
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def new() do
    {ref, {ip, port}} = GenServer.call(__MODULE__, :create)
    {:ok, client_socket} = :gen_tcp.connect(ip, port, [:binary, active: false])

    receive do
      {:server_socket, ^ref, server_socket} ->
        {:ok, client_socket, server_socket}
    after
      1000 ->
        throw("Could not create TCP test tunnel")
    end
  end

  def new(transport) do
    {ref, {ip, port}} = GenServer.call(__MODULE__, :create)
    {:ok, ref, Tortoise.Transport.new({transport, [host: ip, port: port]})}
  end

  # Server callbacks
  def init(state) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {ip, port}} = :inet.sockname(socket)
    {:ok, %{state | socket: socket, ip: ip, port: port}}
  end

  def handle_call(:create, {process_pid, ref} = from, state) do
    GenServer.reply(from, {ref, {state.ip, state.port}})
    # the process should now wait for the caller to accept the socket
    {:ok, server} = :gen_tcp.accept(state.socket, 200)
    :ok = :gen_tcp.controlling_process(server, process_pid)
    send(process_pid, {:server_socket, ref, server})
    {:noreply, state}
  end
end

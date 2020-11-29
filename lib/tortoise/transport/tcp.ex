defmodule Tortoise.Transport.Tcp do
  @moduledoc false

  @behaviour Tortoise.Transport

  alias Tortoise.Transport

  @impl true
  def new(opts) do
    {host, opts} = Keyword.pop(opts, :host)
    {port, opts} = Keyword.pop(opts, :port, 1883)
    {list_opts, opts} = Keyword.pop(opts, :opts, [])
    host = coerce_host(host)
    opts = [:binary, {:packet, :raw}, {:active, false} | opts] ++ list_opts
    %Transport{type: __MODULE__, host: host, port: port, opts: opts}
  end

  defp coerce_host(host) when is_binary(host) do
    String.to_charlist(host)
  end

  defp coerce_host(otherwise) do
    otherwise
  end

  @impl true
  def connect(host, port, opts, timeout) do
    # forced_opts = [:binary, active: false, packet: :raw]
    # opts = Keyword.merge(opts, forced_opts)
    :gen_tcp.connect(host, port, opts, timeout)
  end

  @impl true
  def recv(socket, length, timeout) do
    :gen_tcp.recv(socket, length, timeout)
  end

  @impl true
  def send(socket, data) do
    :gen_tcp.send(socket, data)
  end

  @impl true
  def setopts(socket, opts) do
    :inet.setopts(socket, opts)
  end

  @impl true
  def getopts(socket, opts) do
    :inet.getopts(socket, opts)
  end

  @impl true
  def getstat(socket) do
    :inet.getstat(socket)
  end

  @impl true
  def getstat(socket, opt_names) do
    :inet.getstat(socket, opt_names)
  end

  @impl true
  def controlling_process(socket, pid) do
    :gen_tcp.controlling_process(socket, pid)
  end

  @impl true
  def peername(socket) do
    :inet.peername(socket)
  end

  @impl true
  def sockname(socket) do
    :inet.sockname(socket)
  end

  @impl true
  def shutdown(socket, mode) when mode in [:read, :write, :read_write] do
    :gen_tcp.shutdown(socket, mode)
  end

  @impl true
  def close(socket) do
    :gen_tcp.close(socket)
  end

  @impl true
  def listen(opts) do
    # forced_opts = [:binary, active: false, packet: :raw, reuseaddr: true]
    # opts = Keyword.merge(opts, forced_opts)
    :gen_tcp.listen(0, opts)
  end

  @impl true
  def accept(listen_socket, timeout) do
    :gen_tcp.accept(listen_socket, timeout)
  end

  @impl true
  def accept_ack(_socket, _timeout) do
    :ok
  end
end

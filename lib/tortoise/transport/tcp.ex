defmodule Tortoise.Transport.Tcp do
  @moduledoc false

  @behaviour Tortoise.Transport

  alias Tortoise.Transport

  def new(opts) do
    {host, opts} = Keyword.pop(opts, :host)
    {port, opts} = Keyword.pop(opts, :port, 1883)
    opts = [:binary, {:packet, :raw}, {:active, false} | opts]
    %Transport{type: __MODULE__, host: host, port: port, opts: opts}
  end

  def connect(host, port, opts, timeout) do
    # forced_opts = [:binary, active: false, packet: :raw]
    # opts = Keyword.merge(opts, forced_opts)
    :gen_tcp.connect(host, port, opts, timeout)
  end

  def recv(socket, length, timeout) do
    :gen_tcp.recv(socket, length, timeout)
  end

  def send(socket, data) do
    :gen_tcp.send(socket, data)
  end

  def setopts(socket, opts) do
    :inet.setopts(socket, opts)
  end

  def getopts(socket, opts) do
    :inet.getopts(socket, opts)
  end

  def getstat(socket) do
    :inet.getstat(socket)
  end

  def getstat(socket, opt_names) do
    :inet.getstat(socket, opt_names)
  end

  def controlling_process(socket, pid) do
    :gen_tcp.controlling_process(socket, pid)
  end

  def peername(socket) do
    :inet.peername(socket)
  end

  def sockname(socket) do
    :inet.sockname(socket)
  end

  def shutdown(socket, mode) when mode in [:read, :write, :read_write] do
    :gen_tcp.shutdown(socket, mode)
  end

  def close(socket) do
    :gen_tcp.close(socket)
  end

  def listen(opts) do
    # forced_opts = [:binary, active: false, packet: :raw, reuseaddr: true]
    # opts = Keyword.merge(opts, forced_opts)
    :gen_tcp.listen(0, opts)
  end

  def accept(listen_socket, timeout) do
    :gen_tcp.accept(listen_socket, timeout)
  end

  def accept_ack(_socket, _timeout) do
    :ok
  end
end

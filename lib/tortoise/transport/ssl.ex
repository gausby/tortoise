defmodule Tortoise.Transport.SSL do
  @moduledoc false

  @behaviour Tortoise.Transport

  alias Tortoise.Transport

  @default_opts [verify: :verify_peer]

  def new(opts) do
    {host, opts} = Keyword.pop(opts, :host)
    {port, opts} = Keyword.pop(opts, :port)
    opts = Keyword.merge(@default_opts, opts)
    opts = [:binary, {:packet, :raw}, {:active, false} | opts]
    %Transport{type: __MODULE__, host: host, port: port, opts: opts}
  end

  def connect(host, port, opts, timeout) do
    # [:binary, active: false, packet: :raw]
    :ssl.connect(host, port, opts, timeout)
  end

  def recv(socket, length, timeout) do
    :ssl.recv(socket, length, timeout)
  end

  def send(socket, data) do
    :ssl.send(socket, data)
  end

  def setopts(socket, opts) do
    :ssl.setopts(socket, opts)
  end

  def getopts(socket, opts) do
    :ssl.getopts(socket, opts)
  end

  def getstat(socket) do
    :ssl.getstat(socket)
  end

  def getstat(socket, opt_names) do
    :ssl.getstat(socket, opt_names)
  end

  def controlling_process(socket, pid) do
    :ssl.controlling_process(socket, pid)
  end

  def peername(socket) do
    :ssl.peername(socket)
  end

  def sockname(socket) do
    :ssl.sockname(socket)
  end

  def shutdown(socket, mode) when mode in [:read, :write, :read_write] do
    :ssl.shutdown(socket, mode)
  end

  def close(socket) do
    :ssl.close(socket)
  end

  def listen(opts) do
    case Keyword.has_key?(opts, :cert) do
      true ->
        :ssl.listen(0, opts)

      false ->
        throw("Please specify the cert key for the SSL transport")
    end
  end

  def accept(listen_socket, timeout) do
    :ssl.transport_accept(listen_socket, timeout)
  end

  def accept_ack(client_socket, timeout) do
    case :ssl.ssl_accept(client_socket, timeout) do
      :ok ->
        :ok

      # abnormal data sent to socket
      {:error, {:tls_alert, _}} ->
        :ok = close(client_socket)
        exit(:normal)

      # Socket most likely stopped responding, don't error out.
      {:error, reason} when reason in [:timeout, :closed] ->
        :ok = close(client_socket)
        exit(:normal)

      {:error, reason} ->
        :ok = close(client_socket)
        throw(reason)
    end
  end
end

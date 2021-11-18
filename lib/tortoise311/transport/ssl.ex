defmodule Tortoise311.Transport.SSL do
  @moduledoc false

  @behaviour Tortoise311.Transport

  alias Tortoise311.Transport

  @default_opts [verify: :verify_peer]

  @impl true
  def new(opts) do
    {host, opts} = Keyword.pop(opts, :host)
    {port, opts} = Keyword.pop(opts, :port)
    {list_opts, opts} = Keyword.pop(opts, :opts, [])
    host = coerce_host(host)
    opts = Keyword.merge(@default_opts, opts)
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
    # [:binary, active: false, packet: :raw]
    :ssl.connect(host, port, opts, timeout)
  end

  @impl true
  def recv(socket, length, timeout) do
    :ssl.recv(socket, length, timeout)
  end

  @impl true
  def send(socket, data) do
    :ssl.send(socket, data)
  end

  @impl true
  def setopts(socket, opts) do
    :ssl.setopts(socket, opts)
  end

  @impl true
  def getopts(socket, opts) do
    :ssl.getopts(socket, opts)
  end

  @impl true
  def getstat(socket) do
    :ssl.getstat(socket)
  end

  @impl true
  def getstat(socket, opt_names) do
    :ssl.getstat(socket, opt_names)
  end

  @impl true
  def controlling_process(socket, pid) do
    :ssl.controlling_process(socket, pid)
  end

  @impl true
  def peername(socket) do
    :ssl.peername(socket)
  end

  @impl true
  def sockname(socket) do
    :ssl.sockname(socket)
  end

  @impl true
  def shutdown(socket, mode) when mode in [:read, :write, :read_write] do
    :ssl.shutdown(socket, mode)
  end

  @impl true
  def close(socket) do
    :ssl.close(socket)
  end

  @impl true
  def listen(opts) do
    case Keyword.has_key?(opts, :cert) do
      true ->
        :ssl.listen(0, opts)

      false ->
        throw("Please specify the cert key for the SSL transport")
    end
  end

  @impl true
  def accept(listen_socket, timeout) do
    :ssl.transport_accept(listen_socket, timeout)
  end

  @impl true
  def accept_ack(client_socket, timeout) do
    case :ssl.handshake(client_socket, timeout) do
      {:ok, _} ->
        :ok

      {:ok, _, _} ->
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

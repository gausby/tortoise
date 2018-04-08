defmodule Tortoise.Connection.Connector do
  @moduledoc false

  alias Tortoise.Package

  # Client API
  def start(data) do
    default = data
    GenServer.start(__MODULE__, default)
  end

  # Server callbacks
  def init({:gen_tcp, host, port}, %Package.Connect{} = connect) do
    tcp_opts = [:binary, packet: :raw, active: false]

    with {:ok, socket} <- :gen_tcp.connect(host, port, tcp_opts),
         :ok = :gen_tcp.send(socket, Package.encode(connect)),
         {:ok, packet} <- :gen_tcp.recv(socket, 4, 5000) do
      case Package.decode(packet) do
        %Package.Connack{status: :accepted} = connack ->
          {:ok, socket, connack}

        %Package.Connack{status: {:refused, _reason}} = connack ->
          {:error, connack}

        otherwise ->
          violation = %{expected: Package.Connect, got: otherwise}
          {:error, {:protocol_violation, violation}}
      end
    else
      {:error, :econnrefused} ->
        {:stop, :econnrefused}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

# If the Server accepts a connection with CleanSession set to 1, the
# Server MUST set Session Present to 0 in the CONNACK packet in
# addition to setting a zero return code in the CONNACK packet
# [MQTT-3.2.2-1].

defmodule Tortoise.Pipe do
  @moduledoc """
  The transmitter "pipe", for lack of a better word, is an opaque data
  type that can be given to a process. It contains amongst other
  things a socket.

  A process can obtain a transmitter pipe by subscribing to a
  Transmitter, which will broadcast a updated transmitter pipe when a
  new socket is created for the transmitter.

  The pipe is a one way construction. It is only possible to pour data
  into a pipe, and it will only result in a message control package
  with quality of service zero. If a higher quality of service is
  needed the message should go through the in flight tracker process.

  @todo, document this stuff, and document it better.
  """

  alias Tortoise.{Package, Pipe}
  alias Tortoise.Connection.{Transmitter, Inflight}

  @opaque t :: %__MODULE__{
            client_id: binary(),
            socket: port(),
            module: :tcp,
            active: boolean(),
            failure: :crash | :drop,
            timeout: non_neg_integer() | :infinity,
            pending: [reference()]
          }
  @enforce_keys [:client_id]
  defstruct([
    :client_id,
    socket: nil,
    module: :tcp,
    active: false,
    failure: :crash,
    timeout: :infinity,
    pending: []
  ])

  def new(client_id, opts \\ []) do
    active = Keyword.get(opts, :active, false)
    timeout = Keyword.get(opts, :timeout, 5000)

    opts = [timeout: timeout, active: active]

    case Transmitter.get_socket(client_id, opts) do
      {:ok, socket} ->
        %Pipe{client_id: client_id, socket: socket, active: active}

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  def publish(%Pipe{} = pipe, topic, payload \\ nil, opts \\ []) do
    publish = %Package.Publish{
      topic: topic,
      payload: payload,
      qos: Keyword.get(opts, :qos, 0),
      retain: Keyword.get(opts, :retain, false)
    }

    with %Pipe{} = pipe <- do_publish(pipe, publish) do
      pipe
    else
      {:error, :timeout} ->
        # run pipe error spec
        {:error, :timeout}
    end
  end

  defp do_publish(%Pipe{module: :tcp} = pipe, %Package.Publish{qos: 0} = publish) do
    encoded_publish = Package.encode(publish)

    case :gen_tcp.send(pipe.socket, encoded_publish) do
      :ok ->
        pipe

      {:error, :closed} ->
        case refresh(pipe) do
          %Pipe{} = pipe ->
            do_publish(pipe, publish)

          {:error, :timeout} ->
            {:error, :timeout}
        end
    end
  end

  defp do_publish(%Pipe{client_id: client_id} = pipe, %Package.Publish{qos: qos} = publish)
       when qos in 1..2 do
    case Inflight.track(client_id, {:outgoing, publish}) do
      {:ok, ref} ->
        updated_pending = [ref | pipe.pending]
        %Pipe{pipe | pending: updated_pending}
    end
  end

  defp refresh(%Pipe{active: true, client_id: client_id} = pipe) do
    receive do
      {{Tortoise, ^client_id}, :socket, socket} ->
        %Pipe{pipe | socket: socket}
    after
      pipe.timeout ->
        {:error, :timeout}
    end
  end

  defp refresh(%Pipe{active: false} = pipe) do
    opts = [timeout: pipe.timeout, active: false]

    case Transmitter.get_socket(pipe.client_id, opts) do
      {:ok, socket} ->
        %Pipe{pipe | socket: socket}

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  # protocols
  # defimpl Collectable do
  #   def into(pipe) do
  #     collector_fun = fn
  #       acc, {:cont, %Package.Publish{qos: 0} = elem} ->
  #         [Package.encode(elem) | acc]

  #       acc, :done ->
  #         Transmitter.publish(pipe, Enum.reverse(acc))
  #         acc

  #       _acc, :halt ->
  #         :ok
  #     end

  #     {[], collector_fun}
  #   end
  # end
end

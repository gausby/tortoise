defmodule Tortoise.Connection.Transmitter.Pipe do
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

  alias Tortoise.Package
  alias Tortoise.Connection.Transmitter

  @enforce_keys [:client_id, :socket]
  defstruct [:client_id, :socket, module: :tcp]

  defimpl Collectable do
    def into(pipe) do
      collector_fun = fn
        acc, {:cont, %Package.Publish{qos: 0} = elem} ->
          [Package.encode(elem) | acc]

        acc, :done ->
          Transmitter.publish(pipe, Enum.reverse(acc))
          acc

        _acc, :halt ->
          :ok
      end

      {[], collector_fun}
    end
  end
end

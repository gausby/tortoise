defmodule TestHandler do
  use Tortoise.Handler

  def init(opts) do
    state = Enum.into(opts, %{})
    send(state[:parent], {{__MODULE__, :init}, opts})
    {:ok, state}
  end

  def terminate(reason, state) do
    send(state[:parent], {{__MODULE__, :terminate}, reason})
    :ok
  end

  def handle_message(topic, payload, state) do
    data = %{topic: Enum.join(topic, "/"), payload: payload}
    send(state[:parent], {{__MODULE__, :handle_message}, data})
    {:ok, state}
  end
end

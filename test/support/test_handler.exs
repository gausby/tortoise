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

  def connection(status, state) do
    send(state[:parent], {{__MODULE__, :connection}, status})
    {:ok, state}
  end

  def handle_message(topic, payload, state) do
    data = %{topic: Enum.join(topic, "/"), payload: payload}
    send(state[:parent], {{__MODULE__, :handle_message}, data})
    {:ok, state}
  end

  def subscription(status, topic_filter, state) do
    data = %{status: status, topic_filter: topic_filter}
    send(state[:parent], {{__MODULE__, :subscription}, data})
    {:ok, state}
  end
end

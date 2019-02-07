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

  def handle_disconnect(disconnect, state) do
    send(state[:parent], {{__MODULE__, :handle_disconnect}, disconnect})
    {:stop, :normal, state}
  end

  def handle_publish(_topic, publish, state) do
    # data = %{topic: Enum.join(topic, "/"), payload: payload}
    send(state[:parent], {{__MODULE__, :handle_publish}, publish})
    {:ok, state}
  end

  def handle_pubrec(pubrec, state) do
    send(state[:parent], {{__MODULE__, :handle_pubrec}, pubrec})
    {:cont, state}
  end

  def handle_pubrel(pubrel, state) do
    send(state[:parent], {{__MODULE__, :handle_pubrel}, pubrel})
    {:cont, state}
  end

  def handle_pubcomp(pubcomp, state) do
    send(state[:parent], {{__MODULE__, :handle_pubcomp}, pubcomp})
    {:ok, state}
  end

  def subscription(status, topic_filter, state) do
    data = %{status: status, topic_filter: topic_filter}
    send(state[:parent], {{__MODULE__, :subscription}, data})
    {:ok, state}
  end

  def handle_suback(subscribe, suback, state) do
    send(state[:parent], {{__MODULE__, :handle_suback}, {subscribe, suback}})
    {:ok, state}
  end

  def handle_unsuback(unsubscribe, unsuback, state) do
    send(state[:parent], {{__MODULE__, :handle_unsuback}, {unsubscribe, unsuback}})
    {:ok, state}
  end
end

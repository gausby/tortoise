defmodule Tortoise.Driver.Logger do
  @moduledoc false

  require Logger

  @behaviour Tortoise.Driver

  def init(_opts) do
    {:ok, []}
  end

  def subscription(:up, {topic, qos}, state) do
    Logger.info("Subscribed to #{topic} with QoS #{qos}")
    {:ok, state}
  end

  def subscription(:down, topic, state) do
    Logger.info("Unsubscribed from #{topic}")
    {:ok, state}
  end

  def handle_message(topic, publish, state) do
    Logger.info("#{Enum.join(topic, "/")} #{inspect(publish)}")
    {:ok, state}
  end
end

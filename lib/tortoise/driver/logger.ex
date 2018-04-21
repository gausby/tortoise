defmodule Tortoise.Driver.Logger do
  @moduledoc false

  require Logger

  @behaviour Tortoise.Driver

  def init(_opts) do
    {:ok, []}
  end

  def on_publish(topic, publish, state) do
    Logger.info("#{Enum.join(topic, "/")} #{inspect(publish)}")
    {:ok, state}
  end

  def ping_response(round_trip_time, state) do
    Logger.info("Ping completed in #{round_trip_time}μs")
    {:ok, state}
  end

  def disconnect(_state) do
    Logger.info("Disconnected")
    :ok
  end
end

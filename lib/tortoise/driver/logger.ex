defmodule Tortoise.Driver.Logger do
  @moduledoc false

  require Logger

  @behaviour Tortoise.Driver

  def init(_opts) do
    {:ok, []}
  end

  def handle_message(topic, publish, state) do
    Logger.info("#{Enum.join(topic, "/")} #{inspect(publish)}")
    {:ok, state}
  end

  def disconnect(_state) do
    Logger.info("Disconnected")
    :ok
  end
end

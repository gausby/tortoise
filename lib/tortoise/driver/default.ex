defmodule Tortoise.Driver.Default do
  @moduledoc false

  @behaviour Tortoise.Driver

  defstruct []
  alias __MODULE__, as: State

  def init(_opts) do
    {:ok, %State{}}
  end

  def connection(_status, state) do
    {:ok, state}
  end

  def subscription(_status, _topic, state) do
    {:ok, state}
  end

  def handle_message(_topic, _publish, state) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end
end

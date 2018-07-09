defmodule Tortoise.Handler.Default do
  @moduledoc false

  @behaviour Tortoise.Handler

  defstruct []
  alias __MODULE__, as: State

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def connection(_status, state) do
    {:ok, state}
  end

  @impl true
  def subscription(_status, _topic, state) do
    {:ok, state}
  end

  @impl true
  def handle_message(_topic, _publish, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end

defmodule Tortoise.Connection.Backoff do
  @moduledoc false

  defstruct min_interval: 100, max_interval: 30_000, value: nil
  alias __MODULE__, as: State

  @doc """
  Create an opaque data structure that describe a incremental
  back-off.
  """
  def new(opts) do
    min_interval = Keyword.get(opts, :min_interval, 100)
    max_interval = Keyword.get(opts, :max_interval, 30_000)

    %State{min_interval: min_interval, max_interval: max_interval}
  end

  def next(%State{value: nil} = state) do
    current = state.min_interval
    {current, %State{state | value: current}}
  end

  def next(%State{max_interval: same, value: same} = state) do
    current = state.min_interval
    {current, %State{state | value: current}}
  end

  def next(%State{value: value} = state) do
    current = min(value * 2, state.max_interval)
    {current, %State{state | value: current}}
  end

  def reset(%State{} = state) do
    %State{state | value: nil}
  end
end

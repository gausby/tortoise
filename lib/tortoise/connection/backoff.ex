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
    {0, %State{state | value: state.min_interval}}
  end

  def next(%State{max_interval: value, value: value} = state) do
    {value, %State{state | value: nil}}
  end

  def next(%State{value: value} = state) do
    next = min(value * 2, state.max_interval)
    {value, %State{state | value: next}}
  end

  def reset(%State{} = state) do
    %State{state | value: nil}
  end
end

defmodule Tortoise.Connection.Backoff do
  @moduledoc false

  defstruct min_interval: 100, max_interval: 30_000, timeout: :infinity, total: 0, value: nil
  alias __MODULE__, as: State

  @doc """
  Create an opaque data structure that describe a incremental
  back-off.
  """
  def new(opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    min_interval = Keyword.get(opts, :min_interval, 100)
    max_interval = Keyword.get(opts, :max_interval, 30_000)
    %State{min_interval: min_interval, max_interval: max_interval, timeout: timeout}
  end

  def next(%State{total: total, timeout: timeout}) when total >= timeout do
    {:error, :timeout}
  end

  def next(%State{value: nil} = state) do
    current = state.min_interval
    %State{state | total: state.total + current, value: current}
  end

  def next(%State{max_interval: same, value: same} = state) do
    current = state.min_interval
    %State{state | total: state.total + current, value: current}
  end

  def next(%State{value: value, total: total} = state) do
    current = min(value * 2, state.max_interval)
    %State{state | total: total + current, value: current}
  end

  def reset(%State{} = state) do
    %State{state | total: 0, value: nil}
  end

  def timeout(%State{value: value}) do
    value
  end
end

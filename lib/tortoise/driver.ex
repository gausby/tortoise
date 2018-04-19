defmodule Tortoise.Driver do
  @moduledoc false

  defstruct module: nil, state: nil, initial_args: []

  @doc """
  Helper for building a Driver struct so we can keep it as an opaque
  type in the system.
  """
  def new({module, args}) when is_atom(module) and is_list(args) do
    %__MODULE__{module: module, initial_args: args}
  end

  # identity
  def new(%__MODULE__{} = driver), do: driver

  @type topic() :: [binary()]

  @callback init(term()) :: {:ok, term()}

  # todo, topic should be a list of binary
  @callback on_publish(binary(), binary(), term()) :: {:ok, term()}

  @callback disconnect(term()) :: :ok
end

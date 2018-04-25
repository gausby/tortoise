defmodule Tortoise.Driver do
  @moduledoc false

  @enforce_keys [:module, :initial_args]
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
  @type status() :: :up | :down

  @callback init(term()) :: {:ok, term()}

  @callback connection(status(), term()) :: {:ok, term()}

  @callback subscription(status(), binary(), term()) :: {:ok, term()}

  @callback handle_message(topic(), binary(), term()) :: {:ok, term()}

  @callback terminate(reason, state :: term) :: term
            when reason: :normal | :shutdown | {:shutdown, term}
end

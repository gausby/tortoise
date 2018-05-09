defmodule Tortoise.Handler do
  @moduledoc false

  @enforce_keys [:module, :initial_args]
  defstruct module: nil, state: nil, initial_args: []

  @doc """
  Helper for building a Handler struct so we can keep it as an opaque
  type in the system.
  """
  def new({module, args}) when is_atom(module) and is_list(args) do
    %__MODULE__{module: module, initial_args: args}
  end

  # identity
  def new(%__MODULE__{} = handler), do: handler

  @type topic() :: [binary()]
  @type status() :: :up | :down

  @callback init(args :: term) :: {:ok, state}
            when state: any

  @callback connection(status(), state :: term) :: {:ok, new_state}
            when new_state: term

  @callback subscription(status(), binary(), state :: term) :: {:ok, new_state}
            when new_state: term

  @callback handle_message(topic(), binary(), state :: term) :: {:ok, new_state}
            when new_state: term

  @callback terminate(reason, state :: term) :: term
            when reason: :normal | :shutdown | {:shutdown, term}
end

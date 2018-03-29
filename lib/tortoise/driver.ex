defmodule Tortoise.Driver do
  @moduledoc false

  defstruct module: nil, state: nil, initial_args: []

  @type topic() :: [binary()]

  @callback init(term()) :: {:ok, term()}

  # todo, topic should be a list of binary
  @callback on_publish(binary(), binary(), term()) :: {:ok, term()}

  @callback disconnect(term()) :: :ok
end

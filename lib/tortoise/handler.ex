defmodule Tortoise.Handler do
  @moduledoc false

  alias Tortoise.Package
  alias Tortoise.Connection.Inflight

  @enforce_keys [:module, :initial_args]
  defstruct module: nil, state: nil, initial_args: [], next_actions: []

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

  @doc false
  def execute(handler, :init) do
    case apply(handler.module, :init, [handler.initial_args]) do
      {:ok, initial_state} ->
        {:ok, %__MODULE__{handler | state: initial_state}}
    end
  end

  def execute(handler, {:connection, status}) do
    handler.module
    |> apply(:connection, [status, handler.state])
    |> handle_result(handler)
  end

  def execute(handler, {:publish, %Package.Publish{} = publish}) do
    topic_list = String.split(publish.topic, "/")

    handler.module
    |> apply(:handle_message, [topic_list, publish.payload, handler.state])
    |> handle_result(handler)
  end

  def execute(
        handler,
        {:unsubscribe, %Inflight.Track{type: Package.Unsubscribe, result: unsubacks}}
      ) do
    Enum.reduce(unsubacks, {:ok, handler}, fn topic_filter, {:ok, handler} ->
      handler.module
      |> apply(:subscription, [:down, topic_filter, handler.state])
      |> handle_result(handler)

      # _, {:stop, acc} ->
      #   {:stop, acc}
    end)
  end

  def execute(
        handler,
        {:subscribe, %Inflight.Track{type: Package.Subscribe, result: subacks}}
      ) do
    subacks
    |> flatten_subacks()
    |> Enum.reduce({:ok, handler}, fn {op, topic_filter}, {:ok, handler} ->
      handler.module
      |> apply(:subscription, [op, topic_filter, handler.state])
      |> handle_result(handler)

      # _, {:stop, acc} ->
      #   {:stop, acc}
    end)
  end

  def execute(handler, {:terminate, reason}) do
    _ignored = apply(handler.module, :terminate, [reason, handler.state])
    :ok
  end

  # Subacks will come in a map with three keys in the form of tuples
  # where the fist element is one of `:ok`, `:warn`, or `:error`. This
  # is done to make it easy to pattern match in other parts of the
  # system, and error out early if the result set contain errors. In
  # this part of the system it is more convenient to transform the
  # data to a flat list containing tuples of `{operation, data}` so we
  # can reduce the handler state to collect the possible next actions,
  # and pass through if there is an :error or :disconnect return.
  defp flatten_subacks(subacks) do
    Enum.reduce(subacks, [], fn
      {_, []}, acc ->
        acc

      {:ok, entries}, acc ->
        for {topic_filter, _qos} <- entries do
          {:up, topic_filter}
        end ++ acc

      {:warn, entries}, acc ->
        for {topic_filter, warning} <- entries do
          {{:warn, warning}, topic_filter}
        end ++ acc

      {:error, entries}, acc ->
        for {reason, {topic_filter, _qos}} <- entries do
          {{:error, reason}, topic_filter}
        end ++ acc
    end)
  end

  # handle the user defined return from the callback
  defp handle_result({:ok, updated_state}, handler) do
    {:ok, %__MODULE__{handler | state: updated_state}}
  end

  defp handle_result({:ok, updated_state, next_actions}, handler)
       when is_list(next_actions) do
    case Enum.split_with(next_actions, &valid_next_action?/1) do
      {next_actions, []} ->
        next_actions = handler.next_actions ++ next_actions
        {:ok, %__MODULE__{handler | state: updated_state, next_actions: next_actions}}

      {_, errors} ->
        {:error, {:invalid_next_action, errors}}
    end
  end

  defp valid_next_action?({:subscribe, topic, opts}) do
    is_binary(topic) and is_list(opts)
  end

  defp valid_next_action?({:unsubscribe, topic}) do
    is_binary(topic)
  end

  defp valid_next_action?(_otherwise), do: false
end

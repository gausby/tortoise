defmodule Tortoise.Handler do
  @moduledoc false

  alias Tortoise.Package
  alias Tortoise.Connection.Inflight

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

  @doc false
  def execute(handler, :init) do
    case apply(handler.module, :init, [handler.initial_args]) do
      {:ok, initial_state} ->
        {:ok, %__MODULE__{handler | state: initial_state}}
    end
  end

  def execute(handler, {:connection, status}) do
    args = [status, handler.state]

    case apply(handler.module, :connection, args) do
      {:ok, updated_state} ->
        {:ok, %__MODULE__{handler | state: updated_state}}
    end
  end

  def execute(handler, {:publish, %Package.Publish{} = publish}) do
    topic_list = String.split(publish.topic, "/")
    args = [topic_list, publish.payload, handler.state]

    case apply(handler.module, :handle_message, args) do
      {:ok, updated_state} ->
        {:ok, %__MODULE__{handler | state: updated_state}}
    end
  end

  def execute(
        handler,
        {:unsubscribe, %Inflight.Track{type: Package.Unsubscribe, result: unsubacks}}
      ) do
    updated_handler_state =
      Enum.reduce(unsubacks, handler.state, fn topic_filter, acc ->
        args = [:down, topic_filter, acc]

        case apply(handler.module, :subscription, args) do
          {:ok, state} ->
            state
        end
      end)

    {:ok, %__MODULE__{handler | state: updated_handler_state}}
  end

  def execute(
        handler,
        {:subscribe, %Inflight.Track{type: Package.Subscribe, result: subacks}}
      ) do
    updated_handler_state =
      Enum.reduce(subacks, handler.state, fn
        {_, []}, state ->
          state

        {:ok, oks}, state ->
          Enum.reduce(oks, state, fn {topic_filter, _qos}, acc ->
            args = [:up, topic_filter, acc]

            case apply(handler.module, :subscription, args) do
              {:ok, state} ->
                state
            end
          end)

        {:warn, warns}, state ->
          Enum.reduce(warns, state, fn {topic_filter, warning}, acc ->
            args = [{:warn, warning}, topic_filter, acc]

            case apply(handler.module, :subscription, args) do
              {:ok, state} ->
                state
            end
          end)

        {:error, errors}, state ->
          Enum.reduce(errors, state, fn {reason, {topic_filter, _qos}}, acc ->
            args = [{:error, reason}, topic_filter, acc]

            case apply(handler.module, :subscription, args) do
              {:ok, state} ->
                state
            end
          end)
      end)

    {:ok, %__MODULE__{handler | state: updated_handler_state}}
  end

  def execute(handler, {:terminate, reason}) do
    _ignored = apply(handler.module, :terminate, [reason, handler.state])
    :ok
  end
end

defmodule TestHandler do
  @behaviour Tortoise.Handler

  alias Tortoise.Package

  @impl true
  def init(opts) do
    state = Enum.into(opts, %{})
    send(state[:parent], {{__MODULE__, :init}, opts})
    {:ok, state}
  end

  @impl true
  def handle_connack(%Package.Connack{} = connack, state) do
    case state[:handle_connack] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_connack}, connack})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [connack, state])
    end
  end

  @impl true
  def terminate(reason, state) do
    case state[:terminate] do
      nil ->
        send(state[:parent], {{__MODULE__, :terminate}, reason})
        :ok

      fun when is_function(fun, 2) ->
        apply(fun, [reason, state])
    end
  end

  @impl true
  def status_change(status, state) do
    case state[:status_change] do
      nil ->
        send(state[:parent], {{__MODULE__, :status_change}, status})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [status, state])
    end
  end

  def handle_disconnect(%Package.Disconnect{} = disconnect, state) do
  @impl true
    case state[:handle_disconnect] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_disconnect}, disconnect})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [disconnect, state])
    end
  end

  @impl true
  def handle_publish(topic, %Package.Publish{} = publish, state) do
    case state[:handle_publish] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_publish}, publish})
        {:cont, state}

      fun when is_function(fun, 3) ->
        apply(fun, [topic, publish, state])
    end
  end

  @impl true
  def handle_puback(%Package.Puback{} = puback, state) do
    case state[:handle_puback] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_puback}, puback})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [puback, state])
    end
  end

  @impl true
  def handle_pubrec(%Package.Pubrec{} = pubrec, state) do
    case state[:handle_pubrec] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_pubrec}, pubrec})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [pubrec, state])
    end
  end

  @impl true
  def handle_pubrel(%Package.Pubrel{} = pubrel, state) do
    case state[:handle_pubrel] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_pubrel}, pubrel})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [pubrel, state])
    end
  end

  @impl true
  def handle_pubcomp(%Package.Pubcomp{} = pubcomp, state) do
    case state[:handle_pubcomp] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_pubcomp}, pubcomp})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [pubcomp, state])
    end
  end

  @impl true
  def handle_suback(%Package.Subscribe{} = subscribe, %Package.Suback{} = suback, state) do
    case state[:handle_suback] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_suback}, {subscribe, suback}})
        {:cont, state}

      fun when is_function(fun, 3) ->
        apply(fun, [subscribe, suback, state])
    end
  end

  @impl true
  def handle_unsuback(%Package.Unsubscribe{} = unsubscribe, %Package.Unsuback{} = unsuback, state) do
    case state[:handle_unsuback] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_unsuback}, {unsubscribe, unsuback}})
        {:cont, state}

      fun when is_function(fun, 3) ->
        apply(fun, [unsubscribe, unsuback, state])
    end
  end
end

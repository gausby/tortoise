defmodule TestHandler do
  use Tortoise.Handler

  alias Tortoise.Package

  def init(opts) do
    state = Enum.into(opts, %{})
    send(state[:parent], {{__MODULE__, :init}, opts})
    {:ok, state}
  end

  def handle_connack(%Package.Connack{} = connack, state) do
    case state[:handle_connack] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_connack}, connack})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [connack, state])
    end
  end

  def terminate(reason, state) do
    case state[:terminate] do
      nil ->
        send(state[:parent], {{__MODULE__, :terminate}, reason})
        :ok

      fun when is_function(fun, 2) ->
        apply(fun, [reason, state])
    end
  end

  def connection(status, state) do
    case state[:connection] do
      nil ->
        send(state[:parent], {{__MODULE__, :connection}, status})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [status, state])
    end
  end

  def handle_disconnect(%Package.Disconnect{} = disconnect, state) do
    case state[:handle_disconnect] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_disconnect}, disconnect})
        {:stop, :normal, state}

      fun when is_function(fun, 2) ->
        apply(fun, [disconnect, state])
    end
  end

  def handle_publish(topic, %Package.Publish{} = publish, state) do
    case state[:handle_publish] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_publish}, publish})
        {:cont, state}

      fun when is_function(fun, 3) ->
        apply(fun, [topic, publish, state])
    end
  end

  def handle_puback(%Package.Puback{} = puback, state) do
    case state[:handle_puback] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_puback}, puback})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [puback, state])
    end
  end

  def handle_pubrec(%Package.Pubrec{} = pubrec, state) do
    case state[:handle_pubrec] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_pubrec}, pubrec})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [pubrec, state])
    end
  end

  def handle_pubrel(%Package.Pubrel{} = pubrel, state) do
    case state[:handle_pubrel] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_pubrel}, pubrel})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [pubrel, state])
    end
  end

  def handle_pubcomp(%Package.Pubcomp{} = pubcomp, state) do
    case state[:handle_pubcomp] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_pubcomp}, pubcomp})
        {:cont, state}

      fun when is_function(fun, 2) ->
        apply(fun, [pubcomp, state])
    end
  end

  def handle_suback(%Package.Subscribe{} = subscribe, %Package.Suback{} = suback, state) do
    case state[:handle_suback] do
      nil ->
        send(state[:parent], {{__MODULE__, :handle_suback}, {subscribe, suback}})
        {:cont, state}

      fun when is_function(fun, 3) ->
        apply(fun, [subscribe, suback, state])
    end
  end

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

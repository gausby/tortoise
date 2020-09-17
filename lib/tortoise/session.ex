defmodule Tortoise.Session do
  @moduledoc """
  Keep track of inflight message for a session
  """

  alias __MODULE__
  alias Tortoise.Package

  @enforce_keys [:client_id]
  defstruct backend: {Tortoise.Session.Ets, Tortoise.Session},
            client_id: nil

  def child_spec(opts) do
    mod = Keyword.fetch!(opts, :backend)

    %{
      id: mod,
      start: {mod, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """

  """
  def track(
        %Session{client_id: client_id} = session,
        {:incoming, %Package.Publish{identifier: id, qos: qos, dup: _} = package}
      )
      when not is_nil(id) and qos in 1..2 do
    {backend, ref} = session.backend

    case backend.create(ref, client_id, {:incoming, package}) do
      {:ok, %Package.Publish{identifier: ^id} = package} ->
        {{:cont, package}, session}

      {:error, _reason} = error ->
        error
    end
  end

  def track(
        %Session{client_id: client_id} = session,
        {:outgoing, %type{identifier: _hopefully_nil} = package}
      )
      when type in [Package.Publish, Package.Subscribe, Package.Unsubscribe] do
    {backend, ref} = session.backend

    case backend.create(ref, client_id, {:outgoing, package}) do
      {:ok, %Package.Publish{qos: qos} = package} when qos in 1..2 ->
        # By passing back the package we can allow the backend to
        # monkey with the user defined properties, and set a unique id
        {{:cont, package}, session}

      {:ok, %Package.Subscribe{} = package} ->
        {{:cont, package}, session}

      {:ok, %Package.Unsubscribe{} = package} ->
        {{:cont, package}, session}
    end
  end

  @doc """

  """
  def progress(
        %Session{client_id: client_id} = session,
        {direction, %_type{identifier: id} = package}
      )
      when direction in [:incoming, :outgoing] and id in 0x0001..0xFFFF do
    {backend, ref} = session.backend

    case backend.update(ref, client_id, {direction, package}) do
      {:ok, package} ->
        {{:cont, package}, session}

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """

  """
  def release(
        %Session{backend: {backend, ref}, client_id: client_id} = session,
        id
      )
      when id in 0x0001..0xFFFF do
    :ok = backend.release(ref, client_id, id)
    {:ok, session}
  end
end

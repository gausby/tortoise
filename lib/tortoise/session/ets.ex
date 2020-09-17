defmodule Tortoise.Session.Ets do
  use GenServer

  @name Tortoise.Session

  alias Tortoise.{Session, Package}

  # Client API
  def start_link(opts) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def create(instance \\ @name, session, package)

  def create(instance, session, {:incoming, %Package.Publish{identifier: id} = package})
      when not is_nil(id) do
    do_create(instance, session, {:incoming, package})
  end

  def create(instance, session, {:outgoing, %_type{} = package}) do
    do_create(instance, session, {:outgoing, package})
  end

  # attempt to create an id if none is present
  defp do_create(instance, session, package, attempt \\ 0)

  defp do_create(
         instance,
         %Session{} = session,
         {:outgoing, %type{identifier: nil} = package},
         attempt
       )
       when attempt < 10 do
    <<id::integer-size(16)>> = :crypto.strong_rand_bytes(2)
    data = {:outgoing, %{package | identifier: id}}

    case do_create(instance, session, data, attempt) do
      {:ok, %^type{} = package, session} ->
        {:ok, package, session}

      {:error, :non_unique_package_identifier} ->
        do_create(instance, session, package, attempt + 1)
    end
  end

  defp do_create(_, _, {:outgoing, %_type{identifier: nil}}, _attempt) do
    {:error, :could_not_create_unique_identifier}
  end

  defp do_create(
         instance,
         %Session{client_id: client_id} = session,
         {direction, %{identifier: id} = package},
         _attempt
       )
       when direction in [:incoming, :outgoing] and id in 1..0xFFFF do
    now = System.monotonic_time()

    case :ets.insert_new(instance, {{client_id, id}, {now, direction, package}}) do
      true ->
        {:ok, package, session}

      false ->
        {:error, :non_unique_package_identifier}
    end
  end

  def read(instance \\ @name, %Session{client_id: client_id} = session, package_id) do
    case :ets.lookup(instance, {client_id, package_id}) do
      [{{^client_id, ^package_id}, {_, direction, %_type{identifier: ^package_id} = package}}] ->
        {:ok, {direction, package}, session}

      [] ->
        {:error, :not_found}
    end
  end

  def update(instance \\ @name, session, package)

  def update(
        instance,
        %Session{client_id: client_id} = session,
        {direction, %_type{identifier: package_id} = package}
      ) do
    now = System.monotonic_time()
    key = {client_id, package_id}

    case :ets.update_element(instance, key, {2, {now, direction, package}}) do
      true ->
        {:ok, package, session}

      false ->
        {:error, :not_found}
    end
  end

  def release(instance \\ @name, %Session{client_id: client_id} = session, package_id) do
    true = :ets.delete(instance, {client_id, package_id})
    {:ok, session}
  end

  # Server callbacks
  def init(opts) do
    # do as little as possible, making it really hard to crash the
    # instance state
    name = Keyword.get(opts, :name, @name)
    ref = :ets.new(name, [:named_table, :public, {:write_concurrency, true}])

    {:ok, ref}
  end
end

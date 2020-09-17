defmodule Tortoise.Session.Ets do
  use GenServer

  @name Tortoise.Session

  alias Tortoise.Package

  # Client API
  def start_link(opts) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def create(session \\ @name, client_id, package)

  def create(session, client_id, {:incoming, %Package.Publish{identifier: id} = package})
      when not is_nil(id) do
    do_create(session, client_id, {:incoming, package})
  end

  def create(session, client_id, {:outgoing, %_type{} = package}) do
    do_create(session, client_id, {:outgoing, package})
  end

  # attempt to create an id if none is present
  defp do_create(session, client_id, package, attempt \\ 0)

  defp do_create(session, client_id, {:outgoing, %type{identifier: nil} = package}, attempt)
       when attempt < 10 do
    <<id::integer-size(16)>> = :crypto.strong_rand_bytes(2)
    data = {:outgoing, %{package | identifier: id}}

    case do_create(session, client_id, data, attempt) do
      {:ok, %^type{} = package} ->
        {:ok, package}

      {:error, :non_unique_package_identifier} ->
        do_create(session, client_id, package, attempt + 1)
    end
  end

  defp do_create(_, _, {:outgoing, %_type{identifier: nil}}, _attempt) do
    {:error, :could_not_create_unique_identifier}
  end

  defp do_create(session, client_id, {direction, %{identifier: id} = package}, _attempt)
       when direction in [:incoming, :outgoing] and id in 1..0xFFFF do
    now = System.monotonic_time()

    case :ets.insert_new(session, {{client_id, id}, {now, direction, package}}) do
      true ->
        {:ok, package}

      false ->
        {:error, :non_unique_package_identifier}
    end
  end

  def read(session \\ @name, client_id, package_id) do
    case :ets.lookup(session, {client_id, package_id}) do
      [{{^client_id, ^package_id}, {_, direction, %_type{identifier: ^package_id} = package}}] ->
        {:ok, {direction, package}}

      [] ->
        {:error, :not_found}
    end
  end

  def update(session \\ @name, client_id, package)

  def update(session, client_id, {direction, %_type{identifier: package_id} = package}) do
    now = System.monotonic_time()
    key = {client_id, package_id}

    case :ets.update_element(session, key, {2, {now, direction, package}}) do
      true ->
        {:ok, package}

      false ->
        {:error, :not_found}
    end
  end

  def release(session \\ @name, client_id, package_id) do
    true = :ets.delete(session, {client_id, package_id})
    :ok
  end

  # Server callbacks
  def init(opts) do
    # do as little as possible, making it really hard to crash the
    # session state
    name = Keyword.get(opts, :name, @name)
    ref = :ets.new(name, [:named_table, :public, {:write_concurrency, true}])

    {:ok, ref}
  end
end

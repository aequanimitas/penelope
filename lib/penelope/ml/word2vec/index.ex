defmodule Penelope.ML.Word2vec.Index do
  @moduledoc """
  This module represents a word2vec-style vectorset, compiled into a
  set of hash-partitioned DETS files. Each record is a tuple consisting
  of the term (word) and a set of weights (vector). This module also
  supports parsing the standard text representation of word vectors
  via the compile function.

  On disk, the following files are created:
    <path>/header.dets          index header (version, metadata)
    <path>/<name>_<part>.dets   partition file
  """

  alias __MODULE__, as: Index
  alias Penelope.ML.Vector, as: Vector
  alias Penelope.ML.Word2vec.IndexError, as: IndexError

  defstruct version: 1,
            name: nil,
            partitions: 1,
            vector_size: 300,
            header: nil,
            tables: []

  @type t :: %Index{
          version: pos_integer,
          name: atom,
          partitions: pos_integer,
          vector_size: pos_integer,
          header: atom,
          tables: [atom]
        }
  @version 1

  @doc """
  creates a new word2vec index

  files will be created as <path>/<name>_<part>.dets, one per partition
  """
  @spec create!(
          path :: String.t(),
          name :: String.t(),
          partitions: pos_integer,
          size_hint: pos_integer,
          vector_size: pos_integer
        ) :: Index.t()
  def create!(path, name, options \\ []) do
    name = String.to_atom(name)
    partitions = Keyword.get(options, :partitions, 1)
    vector_size = Keyword.get(options, :vector_size, 300)
    size_hint = div(Keyword.get(options, :size_hint, 200_000), partitions)

    header_data = [
      version: @version,
      name: name,
      partitions: partitions,
      vector_size: vector_size
    ]

    File.mkdir_p!(path)
    header = create_header(path, header_data)

    tables =
      0..(partitions - 1)
      |> Stream.map(&create_table(path, name, &1, size_hint))
      |> Enum.reduce([], &(&2 ++ [&1]))

    %Index{
      version: @version,
      name: name,
      partitions: partitions,
      vector_size: vector_size,
      header: header,
      tables: tables
    }
  end

  defp create_header(path, header) do
    file =
      path
      |> Path.join("header.dets")
      |> String.to_charlist()

    options = [file: file, access: :read_write, type: :set, min_no_slots: 1]

    name = String.to_atom(path)

    with {:ok, file} <- :dets.open_file(name, options),
         :ok <- :dets.insert(file, {:header, header}) do
      file
    else
      {:error, reason} -> raise IndexError, inspect(reason)
    end
  end

  defp create_table(path, name, partition, size_hint) do
    {name, file} = table_file(path, name, partition)

    options = [
      file: file,
      access: :read_write,
      type: :set,
      min_no_slots: size_hint
    ]

    case :dets.open_file(name, options) do
      {:ok, file} -> file
      {:error, reason} -> raise IndexError, inspect(reason)
    end
  end

  defp table_file(path, name, partition) do
    part =
      partition
      |> Integer.to_string()
      |> String.pad_leading(2, "0")

    name = "#{name}_#{part}"

    file =
      path
      |> Path.join("#{name}.dets")
      |> String.to_charlist()

    {String.to_atom(name), file}
  end

  @doc """
  opens an existing word2vec index at the specified path
  """
  @spec open!(path :: String.t(), cache_size: pos_integer) :: Index.t()
  def open!(path, options \\ []) do
    {
      header,
      [
        version: version,
        name: name,
        partitions: partitions,
        vector_size: vector_size
      ]
    } = open_header(path)

    tables =
      0..(partitions - 1)
      |> Stream.map(&open_table(path, name, &1))
      |> Enum.reduce([], &(&2 ++ [&1]))

    cache_size = Keyword.get(options, :cache_size, 1_000_000)

    try do
      :e2qc.setup(name, size: cache_size)
    rescue
      _ in ErlangError -> :ok
    end

    %Index{
      version: version,
      name: name,
      partitions: partitions,
      vector_size: vector_size,
      header: header,
      tables: tables
    }
  end

  defp open_header(path) do
    file =
      path
      |> Path.join("header.dets")
      |> String.to_charlist()

    options = [file: file, access: :read, type: :set]

    name = String.to_atom(path)

    with {:ok, file} <- :dets.open_file(name, options),
         [{:header, header}] <- :dets.lookup(file, :header) do
      {file, header}
    else
      {:error, reason} -> raise IndexError, inspect(reason)
    end
  end

  defp open_table(path, name, partition) do
    {name, file} = table_file(path, name, partition)

    case :dets.open_file(name, file: file, access: :read) do
      {:ok, file} -> file
      {:error, reason} -> raise IndexError, inspect(reason)
    end
  end

  @doc """
  closes the index
  """
  @spec close(index :: Index.t()) :: :ok
  def close(%Index{header: header, tables: tables}) do
    :dets.close(header)
    Enum.each(tables, &:dets.close/1)
  end

  @doc """
  inserts word vectors from a text file into a word2vec index

  the index must have been opened using create()
  """
  @spec compile!(index :: Index.t(), path :: String.t()) :: :ok
  def compile!(index, path) do
    path
    |> File.stream!()
    |> Stream.with_index(_offset = 1)
    |> Task.async_stream(&parse_insert!(index, &1), ordered: false)
    |> Stream.run()
  end

  @doc """
  parses and inserts a single word vector text line into a word2vec index
  """
  @spec parse_insert!(
          index :: Index.t(),
          {line :: String.t(), id :: pos_integer}
        ) :: {String.t(), pos_integer, Vector.t()}
  def parse_insert!(index, {line, id}) do
    {term, vector} = parse_line!(line)
    record = {term, id, vector}
    insert!(index, record)
    record
  end

  @doc """
  parses a word vector line: "<term> <weight> <weight> ..."
  """
  @spec parse_line!(line :: String.t()) :: {String.t(), Vector.t()}
  def parse_line!(line) do
    [term | weights] = String.split(line, " ")

    {term,
     weights
     |> Enum.map(&parse_weight/1)
     |> Vector.from_list()}
  end

  defp parse_weight(str) do
    case Float.parse(str) do
      {value, _remain} -> value
      :error -> raise ArgumentError, "invalid weight: #{str}"
    end
  end

  @doc """
  inserts a word vector tuple into a word2vec index
  """
  @spec insert!(
          index :: Index.t(),
          record :: {String.t(), pos_integer, Vector.t()}
        ) :: :ok
  def insert!(
        %Index{vector_size: vector_size, header: header} = index,
        {term, id, vector} = record
      ) do
    actual_size = div(byte_size(vector), 4)

    unless actual_size === vector_size do
      raise IndexError,
            "invalid vector size: #{actual_size} != #{vector_size}"
    end

    table = get_table(index, elem(record, 0))

    with :ok <- :dets.insert(header, {id, term}),
         :ok <- :dets.insert(table, record) do
      :ok
    else
      {:error, reason} -> raise IndexError, inspect(reason)
    end
  end

  @doc """
  retrieves a term by its id

  if found, returns the term string
  otherwise, returns nil
  """
  @spec fetch!(index :: Index.t(), id :: pos_integer) :: String.t() | nil
  def fetch!(%{name: name} = index, id) do
    :e2qc.cache(name, id, fn -> do_fetch(index, id) end)
  end

  defp do_fetch(%{header: header}, id) do
    case :dets.lookup(header, id) do
      [{_id, term}] -> term
      [] -> nil
      {:error, reason} -> raise IndexError, inspect(reason)
    end
  end

  @doc """
  searches for a term in the word2vec index

  if found, returns the id and word vector (no term)
  otherwise, returns nil
  """
  @spec lookup!(index :: Index.t(), term :: String.t()) ::
          {integer, Vector.t()}
  def lookup!(%{name: name} = index, term) do
    :e2qc.cache(name, term, fn -> do_lookup(index, term) end)
  end

  defp do_lookup(%{vector_size: vector_size} = index, term) do
    bit_size = vector_size * 32

    case index
         |> get_table(term)
         |> :dets.lookup(term) do
      [{_term, id, vector}] -> {id, vector}
      [] -> {0, <<0::size(bit_size)>>}
      {:error, reason} -> raise IndexError, inspect(reason)
    end
  end

  defp get_table(%Index{tables: tables, partitions: partitions}, term) do
    partition = rem(:erlang.phash2(term), partitions)
    Enum.at(tables, partition)
  end
end

defmodule Penelope.ML.Word2vec.IndexError do
  @moduledoc "DETS index processing error"

  defexception message: "an index error occurred"
end

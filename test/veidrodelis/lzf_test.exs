defmodule Veidrodelis.LZFTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Veidrodelis.LZF

  describe "decompress/2" do
    test "decompresses simple literal data" do
      # LZF format: control byte < 32 means literal run
      # Control byte 5 means 6 bytes of literal data follow
      compressed_data = <<5, "Hello!">>
      uncompressed_len = 6

      {:ok, result} = LZF.decompress(compressed_data, uncompressed_len)
      assert result == "Hello!"
    end

    test "handles invalid compressed data" do
      # Data that claims more bytes than available
      compressed_data = <<10, "abc">>
      uncompressed_len = 11

      assert {:error, _} = LZF.decompress(compressed_data, uncompressed_len)
    end

    test "handles empty data" do
      compressed_data = <<>>
      uncompressed_len = 0

      case LZF.decompress(compressed_data, uncompressed_len) do
        {:ok, <<>>} -> :ok
        {:error, _} -> :ok
      end
    end

    test "detects size mismatch" do
      # Compressed data that decompresses to 6 bytes
      compressed_data = <<5, "Hello!">>
      # But we claim it should be 10 bytes
      uncompressed_len = 10

      assert {:error, _} = LZF.decompress(compressed_data, uncompressed_len)
    end

    test "decompresses real LZF data" do
      # Simple literal-only compression
      comp_data = <<3, "test">>
      uncomp_len = 4

      {:ok, result} = LZF.decompress(comp_data, uncomp_len)
      assert result == "test"
    end

    test "decompresses actual data from RDB file" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])

      case File.read(dump_file) do
        {:ok, rdb_binary} ->
          # Find the first occurrence of LZF marker (0xc3)
          case :binary.match(rdb_binary, <<0xC3, 0x40, 0xB1>>) do
            {pos, _} ->
              <<_::binary-size(pos), 0xC3, comp_len_byte1::8, comp_len_byte2::8,
                uncomp_len_byte1::8, uncomp_len_byte2::8, rest::binary>> = rdb_binary

              # Decode the length values (14-bit encoding)
              comp_len = (comp_len_byte1 &&& 0x3F <<< 8) ||| comp_len_byte2
              uncomp_len = (uncomp_len_byte1 &&& 0x3F <<< 8) ||| uncomp_len_byte2

              <<comp_data::binary-size(comp_len), _::binary>> = rest

              # Decompress using our NIF
              {:ok, decompressed} = LZF.decompress(comp_data, uncomp_len)

              assert byte_size(decompressed) == uncomp_len

              # Verify it's a valid listpack
              <<total_bytes::32-little, num_entries::16-little, _::binary>> = decompressed

              assert total_bytes > 0
              assert num_entries > 0

            :nomatch ->
              flunk("Could not find LZF compressed data in RDB file")
          end

        {:error, _} ->
          # Skip test if dump file not found
          :ok
      end
    end
  end

  describe "compress/1" do
    test "compresses simple data" do
      uncompressed_data = "Hello, World!"

      {:ok, compressed} = LZF.compress(uncompressed_data)
      assert is_binary(compressed)
      assert byte_size(compressed) > 0
    end

    test "compresses repetitive data efficiently" do
      # Highly repetitive data should compress very well
      repetitive_data = String.duplicate("a", 1000)

      {:ok, compressed} = LZF.compress(repetitive_data)

      # Should compress to much less than original
      assert byte_size(compressed) < div(byte_size(repetitive_data), 10)

      # Verify decompression
      {:ok, decompressed} = LZF.decompress(compressed, byte_size(repetitive_data))
      assert decompressed == repetitive_data
    end
  end

  describe "compress/decompress roundtrip" do
    test "preserves data through compress-decompress cycle" do
      test_data = [
        "Hello, World!",
        "This is a test string",
        "Short",
        "A much longer string that contains more data and might compress better",
        <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>,
        # Highly compressible
        String.duplicate("a", 100)
      ]

      for original_data <- test_data do
        {:ok, compressed} = LZF.compress(original_data)
        {:ok, decompressed} = LZF.decompress(compressed, byte_size(original_data))

        assert decompressed == original_data
      end
    end
  end
end

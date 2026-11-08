import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final qwen14b = ModelCatalog.qwen3.singleWhere((m) => m.displayName == 'Qwen3-14B');

  group('MemoryEstimator', () {
    test('kv cache of Qwen3-14B at 16k context matches the spec review figure', () {
      // 2 x 40 layers x 8 heads x 128 dims x 2 bytes x 16384 tokens = 2.5 GiB
      expect(MemoryEstimator.kvCacheBytes(qwen14b, 16384, KvCacheType.f16), 2684354560);
    });

    test('q8 kv cache roughly halves the cost', () {
      final f16 = MemoryEstimator.kvCacheBytes(qwen14b, 16384, KvCacheType.f16);
      final q8 = MemoryEstimator.kvCacheBytes(qwen14b, 16384, KvCacheType.q8_0);
      final q4 = MemoryEstimator.kvCacheBytes(qwen14b, 16384, KvCacheType.q4_0);
      expect(q8, lessThan(f16 * 0.55));
      expect(q4, lessThan(f16 * 0.30), reason: 'q4_0 takes 18 bytes where f16 takes 64 for the same 32 values');
      expect(q4, lessThan(q8));
    });

    test('greys out a model that does not fit', () {
      const gib = 1 << 30;
      expect(MemoryEstimator.fits(qwen14b, 16384, KvCacheType.f16, 8 * gib), isFalse);
      expect(MemoryEstimator.fits(qwen14b, 4096, KvCacheType.f16, 16 * gib), isTrue);
    });
  });

  group('ModelCatalog', () {
    test('basic model is the small Qwen3.5 and fits a 4 GB phone', () {
      expect(ModelCatalog.basic.paramsB, 0.8);
      expect(MemoryEstimator.fits(ModelCatalog.basic, 8192, KvCacheType.f16, 4000000000), isTrue);
    });

    test('hybrid attention keeps the KV cache small', () {
      // 2 x 6 full-attention layers x 2 heads x 256 dims x 2 bytes x 4096 tokens = 48 MiB
      expect(MemoryEstimator.kvCacheBytes(ModelCatalog.basic, 4096, KvCacheType.f16), 50331648);
    });

    test('ids and file names are unique', () {
      expect(ModelCatalog.all.map((m) => m.id).toSet().length, ModelCatalog.all.length);
      expect(ModelCatalog.all.map((m) => m.fileName).toSet().length, ModelCatalog.all.length);
    });

    test('lookup by file name and params parsing', () {
      expect(ModelCatalog.byFileName('Qwen3.5-0.8B-Q8_0.gguf'), same(ModelCatalog.basic));
      expect(ModelCatalog.byFileName('other.gguf'), isNull);
      expect(ModelCatalog.byFileName('Qwen3-1.7B_dynamic_wi4b32_afp32.litertlm')?.paramsB, 1.7);
      expect(ModelCatalog.byFileName('qwen3_4b_mixed_int4.litertlm')?.format, ModelFormat.litertLm);
    });
  });
}

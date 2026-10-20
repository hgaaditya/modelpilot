# Model support contract

Model Pilot distinguishes a model that is configured from a model whose text-generation path was actually exercised.

| State in Models | Meaning | It does not promise |
|---|---|---|
| `engine missing` | The configured runtime binary is absent. | That downloading weights will fix an incompatible model format. |
| `ready — verify response` | GGUF weights and its selected engine are present. | A successful load, answer quality, tool calling, vision, or a particular context size. |
| `text response verified` | **Test a real response** received non-empty text through llama-swap. The panel records the timestamp locally in `.model-support.json`. | Benchmark performance, instruction quality, tool use, vision/image input, long-context recall, or multi-step agent reliability. |

Verification is local to the installation and is deliberately invalidated only by the user changing/removing files; it is evidence of a completed text response, not a vendor certification.

Use **Tune** to measure context on the current hardware. Use a model's own licence and upstream model card for redistribution, safety, modality, and trained-context claims.

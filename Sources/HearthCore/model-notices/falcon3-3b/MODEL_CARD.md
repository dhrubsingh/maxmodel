---
base_model: tiiuae/Falcon3-3B-Instruct
language:
- en
- fr
- es
- pt
library_name: transformers
license: other
license_name: falcon-llm-license
license_link: https://falconllm.tii.ae/falcon-terms-and-conditions.html
tags:
- falcon3
---

<div align="center">
    <img src="https://huggingface.co/datasets/tiiuae/documentation-images/resolve/main/general/falco3-logo.png" alt="drawing" width="500"/>
</div>

# Falcon3-3B-Instruct

**Falcon3** family of Open Foundation Models is a set of pretrained and instruct LLMs ranging from 1B to 10B parameters.

**Falcon3-3B-Instruct** achieves strong results on reasoning, language understanding, instruction following, code and mathematics tasks.
Falcon3-3B-Instruct supports 4 languages (English, French, Spanish, Portuguese) and a context length of up to 32K.

## Model Details
- Architecture
  - Transformer-based causal decoder-only architecture
  - 22 decoder blocks
  - Grouped Query Attention (GQA) for faster inference: 12 query heads and 4 key-value heads
  - Wider head dimension: 256
  - High RoPE value to support long context understanding: 1000042
  - Uses SwiGLU and RMSNorm
  - 32K context length
  - 131K vocab size
- Pruned and healed from Falcon3-7B-Base on only 100 Gigatokens of datasets comprising of web, code, STEM, high quality and mutlilingual data using 1024 H100 GPU chips
- Posttrained on 1.2 million samples of STEM, conversational, code, safety and function call data
- Supports EN, FR, ES, PT
- Developed by [Technology Innovation Institute](https://www.tii.ae)
- License: TII Falcon-LLM License 2.0
- Model Release Date: December 2024


## Getting started

<details>
<summary> Click to expand </summary>

```python
from transformers import AutoTokenizer, AutoModelForCausalLM

model_name = "tiiuae/Falcon3-3B-Instruct"

model = AutoModelForCausalLM.from_pretrained(
    model_name,
    torch_dtype="auto",
    device_map="auto"
)
tokenizer = AutoTokenizer.from_pretrained(model_name)

prompt = "How many hours in one day?"
messages = [
    {"role": "system", "content": "You are a helpful friendly assistant Falcon3 from TII, try to follow instructions as much as possible."},
    {"role": "user", "content": prompt}
]
text = tokenizer.apply_chat_template(
    messages,
    tokenize=False,
    add_generation_prompt=True
)
model_inputs = tokenizer([text], return_tensors="pt").to(model.device)

generated_ids = model.generate(
    **model_inputs,
    max_new_tokens=1024
)
generated_ids = [
    output_ids[len(input_ids):] for input_ids, output_ids in zip(model_inputs.input_ids, generated_ids)
]

response = tokenizer.batch_decode(generated_ids, skip_special_tokens=True)[0]
print(response)
```

</details>

<br>

## Benchmarks
We report in the following table our internal pipeline benchmarks.
 - We use [lm-evaluation harness](https://github.com/EleutherAI/lm-evaluation-harness).
 - We report **raw scores** obtained by applying chat template and fewshot_as_multiturn.
 - We use same batch-size across all models.

<table border="1" style="width: 100%; text-align: center; border-collapse: collapse;">
    <colgroup>
        <col style="width: 10%;">
        <col style="width: 10%;">
        <col style="width: 7%;">
        <col style="width: 7%;">
        <col style="width: 7%;">
        <col style="background-color: rgba(80, 15, 213, 0.5); width: 7%;">
    </colgroup>
    <thead>
        <tr>
            <th>Category</th>
            <th>Benchmark</th>
            <th>Llama-3.2-3B-Instruct</th>
            <th>Qwen2.5-3B-Instruct</th>
            <th>Nemotron-Mini-4B-Instruct</th>
            <th>Falcon3-3B-Instruct</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td rowspan="3">General</td>
            <td>MMLU (5-shot)</td>
            <td>61.2</td>
            <td><b>65.4</b></td>
            <td>57.3</td>
            <td>56.9</td>
        </tr>
        <tr>
            <td>MMLU-PRO (5-shot)</td>
            <td>27.7</td>
            <td><b>32.6</b></td>
            <td>26.0</td>
            <td>29.7</td>
        </tr>
        <tr>
            <td>IFEval</td>
            <td><b>74.7</b></td>
            <td>64.1</td>
            <td>66.3</td>
            <td>68.3</td>
        </tr>
        <tr>
            <td rowspan="3">Math</td>
            <td>GSM8K (5-shot)</td>
            <td><b>76.8</b></td>
            <td>56.7</td>
            <td>29.8</td>
            <td>74.8</td>
        </tr>
        <tr>
            <td>GSM8K (8-shot, COT)</td>
            <td><b>78.8</b></td>
            <td>60.8</td>
            <td>35.0</td>
            <td>78.0</td>
        </tr>
        <tr>
            <td>MATH Lvl-5 (4-shot)</td>
            <td>14.6</td>
            <td>0.0</td>
            <td>0.0</td>
            <td><b>19.9</b></td>
        </tr>
        <tr>
            <td rowspan="5">Reasoning</td>
            <td>Arc Challenge (25-shot)</td>
            <td>50.9</td>
            <td>55.0</td>
            <td><b>56.2</b></td>
            <td>55.5</td>
        </tr>
        <tr>
            <td>GPQA (0-shot)</td>
            <td><b>32.2</b></td>
            <td>29.2</td>
            <td>27.0</td>
            <td>29.6</td>
        </tr>
        <tr>
            <td>GPQA (0-shot, COT)</td>
            <td>11.3</td>
            <td>11.0</td>
            <td>12.2</td>
            <td><b>26.5</b></td>
        </tr>
        <tr>
            <td>MUSR (0-shot)</td>
            <td>35.0</td>
            <td><b>40.2</b></td>
            <td>38.7</td>
            <td>39.0</td>
        </tr>
        <tr>
            <td>BBH (3-shot)</td>
            <td>41.8</td>
            <td>44.5</td>
            <td>39.5</td>
            <td><b>45.4</b></td>
        </tr>
        <tr>
            <td rowspan="4">CommonSense Understanding</td>
            <td>PIQA (0-shot)</td>
            <td>74.6</td>
            <td>73.8</td>
            <td>74.6</td>
            <td><b>75.6</b></td>
        </tr>
        <tr>
            <td>SciQ (0-shot)</td>
            <td>77.2</td>
            <td>60.7</td>
            <td>71.0</td>
            <td><b>95.5</b></td>
        </tr>
        <tr>
            <td>Winogrande (0-shot)</td>
            <td>-</td>
            <td>-</td>
            <td>-</td>
            <td><b>65.0</b></td>
        </tr>
        <tr>
            <td>OpenbookQA (0-shot)</td>
            <td>40.8</td>
            <td>41.2</td>
            <td><b>43.2</b></td>
            <td>42.2</td>
        </tr>
        <tr>
            <td rowspan="2">Instructions following</td>
            <td>MT-Bench (avg)</td>
            <td>7.1</td>
            <td><b>8.0</b></td>
            <td>6.7</td>
            <td>7.2</td>
        </tr>
        <tr>
            <td>Alpaca (WC)</td>
            <td><b>19.4</b></td>
            <td>19.4</td>
            <td>9.6</td>
            <td>15.5</td>
        </tr>
        <tr>
            <td>Tool use</td>
            <td>BFCL AST (avg)</td>
            <td><b>85.2</b></td>
            <td>84.8</td>
            <td>59.8</td>
            <td>59.3</td>
        </tr>
      <tr>
            <td rowspan="2">Code</td>
            <td>EvalPlus (0-shot) (avg)</td>
            <td>55.2</td>
            <td><b>69.4<b></td>
            <td>40.0</td>
            <td>52.9</td>
        </tr>
        <tr>
            <td>Multipl-E (0-shot) (avg)</td>
            <td>31.6</td>
            <td>29.2</td>
            <td>19.6</td>
            <td><b>32.9</b></td>
        </tr>   
    </tbody>
</table>

## Useful links
- View our [release blogpost](https://huggingface.co/blog/falcon3).
- Feel free to join [our discord server](https://discord.gg/fwXpMyGc) if you have any questions or to interact with our researchers and developers.

## Technical Report
Coming soon....

## Citation
If the Falcon3 family of models were helpful to your work, feel free to give us a cite.
 
```
@misc{Falcon3,
    title = {The Falcon 3 Family of Open Models},
    url = {https://huggingface.co/blog/falcon3},
    author = {Falcon-LLM Team},
    month = {December},
    year = {2024}
}
```

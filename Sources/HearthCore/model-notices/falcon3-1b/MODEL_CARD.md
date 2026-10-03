---
language:
- en
- fr
- es
- pt
tags:
- falcon3
base_model: tiiuae/Falcon3-1B-Base
license: other
license_name: falcon-llm-license
license_link: https://falconllm.tii.ae/falcon-terms-and-conditions.html
library_name: transformers
---

<div align="center">
    <img src="https://huggingface.co/datasets/tiiuae/documentation-images/resolve/main/general/falco3-logo.png" alt="drawing" width="500"/>
</div>

# Falcon3-1B-Instruct

**Falcon3** family of Open Foundation Models is a set of pretrained and instruct LLMs ranging from 1B to 10B parameters.

This repository contains the **Falcon3-1B-Instruct**. It achieves strong results on reasoning, language understanding, instruction following, code and mathematics tasks.
Falcon3-1B-Instruct supports 4 languages (English, French, Spanish, Portuguese) and a context length of up to 8K.

## Model Details
- Architecture
  - Transformer-based causal decoder-only architecture
  - 18 decoder blocks
  - Grouped Query Attention (GQA) for faster inference: 8 query heads and 4 key-value heads
  - Wider head dimension: 256
  - High RoPE value to support long context understanding: 1000042
  - Uses SwiGLU and RMSNorm
  - 8K context length
  - 131K vocab size
- Pruned and healed using larger Falcon models (3B and 7B respectively) on only 80 Gigatokens of datasets comprising of web, code, STEM, high quality and multilingual data using 256 H100 GPU chips
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


model_name = "tiiuae/Falcon3-1B-Instruct"

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
            <th>Llama-3.2-1B</th>
            <th>Qwen2.5-1.5B</th>
            <th>SmolLM2-1.7B</th>
            <th>Falcon3-1B-Instruct</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td rowspan="3">General</td>
            <td>MMLU (5-shot)</td>
            <td><b>68.2</b></td>
            <td>59.8</td>
            <td>49.2</td>
            <td>46.1</td>
        </tr>
        <tr>
            <td>MMLU-PRO (5-shot)</td>
            <td>16</td>
            <td><b>28.2</b></td>
            <td>20</td>
            <td>18.6</td>
        </tr>
        <tr>
            <td>IFEval</td>
            <td><b>55.3</b></td>
            <td>44.2</td>
            <td>53</td>
            <td>54.4</td>
        </tr>
        <tr>
            <td rowspan="3">Math</td>
            <td>GSM8K (5-shot)</td>
            <td><b>82.6</b></td>
            <td>57.8</td>
            <td>47.6</td>
            <td>43.9</td>
        </tr>
        <tr>
            <td>GSM8K (8-shot, COT)</td>
            <td>46.6</td>
            <td><b>58.8</b></td>
            <td>46.3</td>
            <td>45.8</td>
        </tr>
        <tr>
            <td>MATH Lvl-5 (4-shot)</td>
            <td><b>5.2</b></td>
            <td>1.1</td>
            <td>3.1</td>
            <td>1</td>
        </tr>
        <tr>
            <td rowspan="5">Reasoning</td>
            <td>Arc Challenge (25-shot)</td>
            <td><b>58.6</b></td>
            <td>50.7</td>
            <td>49.7</td>
            <td>47.7</td>
        </tr>
        <tr>
            <td>GPQA (0-shot)</td>
            <td>24.4</td>
            <td><b>29.6</b></td>
            <td>28.6</td>
            <td>26.5</td>
        </tr>
        <tr>
            <td>GPQA (0-shot, COT)</td>
            <td>13.2</td>
            <td>9.2</td>
            <td>16</td>
            <td><b>21.3</b></td>
        </tr>
        <tr>
            <td>MUSR (0-shot)</td>
            <td>32</td>
            <td>36.5</td>
            <td>32.9</td>
            <td><b>40.7</b></td>
        </tr>
        <tr>
            <td>BBH (3-shot)</td>
            <td>33.8</td>
            <td><b>39.2</b></td>
            <td>34</td>
            <td>35.1</td>
        </tr>
        <tr>
            <td rowspan="5">CommonSense Understanding</td>
            <td>PIQA (0-shot)</td>
            <td>72.1</td>
            <td>73.2</td>
            <td><b>74.4</b></td>
            <td>72</td>
        </tr>
        <tr>
            <td>SciQ (0-shot)</td>
            <td>61.8</td>
            <td>69.5</td>
            <td>71.4</td>
            <td><b>86.8</b></td>
        </tr>
        <tr>
            <td>Winogrande (0-shot)</td>
            <td>-</td>
            <td>-</td>
            <td>-</td>
            <td><b>60.2</b></td>
        </tr>
        <tr>
            <td>OpenbookQA (0-shot)</td>
            <td>40.2</td>
            <td>40.4</td>
            <td><b>42.8</b></td>
            <td>40</td>
        </tr>
        <tr>
            <td>MT-Bench (avg)</td>
            <td>5.4</td>
            <td><b>7.1</b></td>
            <td>6.1</td>
            <td>5.5</td>
        </tr>
        <tr>
            <td rowspan="1">Instructions following</td>
            <td>Alpaca (WC)</td>
            <td><b>8.6</b></td>
            <td><b>8.6</b></td>
            <td>5.4</td>
            <td>6.1</td>
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
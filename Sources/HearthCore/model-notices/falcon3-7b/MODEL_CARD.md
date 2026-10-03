---
language:
- en
- fr
- es
- pt
tags:
- falcon3
base_model: tiiuae/Falcon3-7B-Base
license: other
license_name: falcon-llm-license
license_link: https://falconllm.tii.ae/falcon-terms-and-conditions.html
library_name: transformers
---

<div align="center">
    <img src="https://huggingface.co/datasets/tiiuae/documentation-images/resolve/main/general/falco3-logo.png" alt="drawing" width="500"/>
</div>

# Falcon3-7B-Instruct

**Falcon3** family of Open Foundation Models is a set of pretrained and instruct LLMs ranging from 1B to 10B.

This repository contains the **Falcon3-7B-Instruct**. It achieves state of art results (at the time of release) on reasoning, language understanding, instruction following, code and mathematics tasks.
Falcon3-7B-Instruct supports 4 languages (english, french, spanish, portuguese) and a context length up to 32K.

## Model Details
- Architecture
  - Transformer based causal decoder only architecture
  - 28 decoder blocks
  - Grouped query attention (GQA) for faster inference: 12 query heads and 4 key value heads
  - Wider head dimension: 256
  - High RoPE value to support long context understanding: 1000042
  - Uses SwiGLU and RMSNorm
  - 32K context length
  - 131K vocab size
- Pretrained on 14 Teratokens of datasets comprising of web, code, STEM, high quality and mutlilingual data using 1024 H100 GPU chips
- Postrained on 1.2 million samples of STEM, conversations, code, safety and function call data
- Supports EN, FR, ES, PT
- Developed by [Technology Innovation Institute](https://www.tii.ae)
- License: TII Falcon-LLM License 2.0
- Model Release Date: December 2024


## Getting started

<details>
<summary> Click to expand </summary>

```python

from transformers import AutoModelForCausalLM, AutoTokenizer

model_name = "tiiuae/Falcon3-7B-Instruct"

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
We report the official HuggingFace leaderboard normalized evaluations [Open LLM Leaderboard Evaluation Results](https://huggingface.co/spaces/open-llm-leaderboard/open_llm_leaderboard) in the following table.
<table border="1" style="width: 100%; text-align: center; border-collapse: collapse;">
    <colgroup>
        <col style="width: 10%;">
        <col style="width: 7%;">
        <col style="width: 7%;">
        <col style="background-color: rgba(80, 15, 213, 0.5); width: 7%;">
    </colgroup>
    <thead>
        <tr>
            <th>Benchmark</th>
            <th>Llama-3.1-8B-Instruct</th>
            <th>Qwen2.5-7B-Instruct</th>
            <th>Falcon3-7B-Instruct</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td>IFEval</td>
            <td><b>78.56</b></td>
            <td>75.85</td>
            <td>76.12</td>
        </tr>
        <tr>
            <td>BBH (3-shot)</td>
            <td>29.89</td>
            <td>34.89</td>
            <td><b>37.92</b></td>
        </tr>
        <tr>
            <td>MATH Lvl-5 (4-shot)</td>
            <td>19.34</td>
            <td>0.00</td>
            <td><b>31.87</b></td>
        </tr>              
        <tr>
            <td>GPQA (0-shot)</td>
            <td>2.35</td>
            <td>5.48</td>
            <td><b>8.05</b></td>
        </tr>
        <tr>
            <td>MUSR (0-shot)</td>
            <td>8.41</td>
            <td>8.45</td>
            <td><b>21.17</b></td>
        </tr>
        <tr>
            <td>MMLU-PRO (5-shot)</td>
            <td>30.68</td>
            <td><b>36.52</b></td>
            <td>34.30</td>
        </tr>        
    </tbody>
</table>

Also, we report in the following table our internal pipeline benchmarks.
 - We use [lm-evaluation harness](https://github.com/EleutherAI/lm-evaluation-harness).
 - We report **raw scores** obtained by applying chat template and fewshot_as_multiturn.
 - We use same batch-size across all models.

<table border="1" style="width: 100%; text-align: center; border-collapse: collapse;">
    <colgroup>
        <col style="width: 10%;">
        <col style="width: 10%;">
        <col style="width: 7%;">
        <col style="width: 7%;">
        <col style="background-color: rgba(80, 15, 213, 0.5); width: 7%;">
    </colgroup>
    <thead>
        <tr>
            <th>Category</th>
            <th>Benchmark</th>
            <th>Llama-3.1-8B-Instruct</th>
            <th>Qwen2.5-7B-Instruct</th>
            <th>Falcon3-7B-Instruct</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td rowspan="3">General</td>
            <td>MMLU (5-shot)</td>
            <td>68.2</td>
            <td><b>73.5</b></td>
            <td>70.5</td>
        </tr>
        <tr>
            <td>MMLU-PRO (5-shot)</td>
            <td>36.4</td>
            <td><b>43.1</b></td>
            <td>40.7</td>
        </tr>
        <tr>
            <td>IFEval</td>
            <td><b>78.8</b></td>
            <td>74.7</td>
            <td>76.5</td>
        </tr>
        <tr>
            <td rowspan="3">Math</td>
            <td>GSM8K (5-shot)</td>
            <td><b>82.6</b></td>
            <td>72.0</td>
            <td>81.4</td>
        </tr>
        <tr>
            <td>GSM8K (8-shot, COT)</td>
            <td><b>85.4</b></td>
            <td>76.6</td>
            <td>79.7</td>
        </tr>
        <tr>
            <td>MATH Lvl-5 (4-shot)</td>
            <td>15.4</td>
            <td>-</td>
            <td><b>29.4</b></td>
        </tr>
        <tr>
            <td rowspan="5">Reasoning</td>
            <td>Arc Challenge (25-shot)</td>
            <td>58.6</td>
            <td>57.8</td>
            <td><b>62.6</b></td>
        </tr>
        <tr>
            <td>GPQA (0-shot)</td>
            <td><b>33.5</b></td>
            <td>32</td>
            <td>31.9</td>
        </tr>
        <tr>
            <td>GPQA (0-shot, COT)</td>
            <td>9.6</td>
            <td>13.8</td>
            <td><b>22.3</b></td>
        </tr>
        <tr>
            <td>MUSR (0-shot)</td>
            <td>38.6</td>
            <td>41</td>
            <td><b>46.4</b></td>
        </tr>
        <tr>
            <td>BBH (3-shot)</td>
            <td>48.6</td>
            <td><b>54.1</b></td>
            <td>52.4</td>
        </tr>
        <tr>
            <td rowspan="4">CommonSense Understanding</td>
            <td>PIQA (0-shot)</td>
            <td><b>78.9</b></td>
            <td>73.7</td>
            <td>78.8</td>
        </tr>
        <tr>
            <td>SciQ (0-shot)</td>
            <td>80.2</td>
            <td>50.9</td>
            <td><b>94.7</b></td>
        </tr>
        <tr>
            <td>Winogrande (0-shot)</td>
            <td>-</td>
            <td>-</td>
            <td>70.4</td>
        </tr>
        <tr>
            <td>OpenbookQA (0-shot)</td>
            <td><b>46.2</b></td>
            <td>42.4</td>
            <td>45.8</td>
        </tr>
        <tr>
            <td rowspan="2">Instructions following</td>
            <td>MT-Bench (avg)</td>
            <td>7.9</td>
            <td><b>8.5</b></td>
            <td>8.4</td>
        </tr>
        <tr>
            <td>Alpaca (WC)</td>
            <td>26.6</td>
            <td><b>31.5</b></td>
            <td>26.1</td>
        </tr>
        <tr>
            <td>Tool use</td>
            <td>BFCL AST (avg)</td>
            <td>90.6</td>
            <td><b>91.4</b></td>
            <td>89.5</td>
        </tr>
    </tbody>
</table>

## Useful links
- View our [release blogpost](https://huggingface.co/blog/falcon3).
- Feel free to join [our discord server](https://discord.gg/fwXpMyGc) if you have any questions or to interact with our researchers and developers.

## Technical Report
Coming soon....

## Citation
If Falcon3 family were helpful to your work, feel free to give us a cite.

```
@misc{Falcon3,
    title = {The Falcon 3 family of Open Models},
    author = {TII Team},
    month = {December},
    year = {2024}
}
```

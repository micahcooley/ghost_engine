pub const default_weights_path = "weights/gemma-4-E2B-it-Q8_0.gguf";
pub const default_system_prompt_path = "prompts/gemma_system.txt";
pub const default_response_format_path = "prompts/gemma_response_format.txt";

pub const hypervector_bits: usize = 1024;
pub const default_block_count: usize = 35;
pub const default_embedding_length: usize = 1536;
pub const default_attention_head_count: usize = 8;
pub const default_attention_head_count_kv: usize = 1;
pub const default_attention_key_length: usize = 512;
pub const default_attention_key_length_swa: usize = 256;
pub const default_attention_value_length: usize = 512;
pub const default_attention_value_length_swa: usize = 256;
pub const default_embedding_length_per_layer_input: usize = 256;
pub const default_query_projection_length: usize = 2048;
pub const default_attention_top_k: usize = 32;
pub const default_projection_lr: f32 = 0.0001;
pub const default_rune_etch_threshold: f32 = 0.4;
pub const default_ffn_dim_by_layer = [_]usize{
    6144,  6144,  6144,  6144,  6144,  6144,  6144,  6144,  6144,  6144,
    6144,  6144,  6144,  6144,  6144,  12288, 12288, 12288, 12288, 12288,
    12288, 12288, 12288, 12288, 12288, 12288, 12288, 12288, 12288, 12288,
    12288, 12288, 12288, 12288, 12288,
};

pub const supported_architecture = "gemma4";
pub const metadata_driven_shape = true;

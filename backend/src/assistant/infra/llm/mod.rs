//! Generic language-model transport kept local to the assistant context.

mod openai;

pub(crate) use openai::{
    Auth, ChatClient, ChatError, ChatImage, ChatMessage, ChatRequest, ChatResponse, ChatRole,
    OpenAiClient, OpenAiConfig, ResponseFormat, TokenUsage,
};

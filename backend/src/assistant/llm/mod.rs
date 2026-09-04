//! Generic language-model transport kept local to the assistant context.

mod openai_compatible;

pub(crate) use openai_compatible::{
    Authentication, ChatClient, ChatError, ChatMessage, ChatRequest, ChatResponse, ChatRole,
    OpenAiCompatibleClient, OpenAiCompatibleConfig, ResponseFormat, TokenUsage,
};

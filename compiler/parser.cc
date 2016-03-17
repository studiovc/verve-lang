#include "parser.h"

#include "lexer.h"
#include "token.h"

namespace ceos {

  std::shared_ptr<AST::Program> Parser::parse(void) {
    m_ast = std::make_shared<AST::Program>();

    m_lexer.nextToken();
    while (m_lexer.token()->type != Token::Type::END) {
      std::shared_ptr<AST> node = parseFactor();
      m_ast->addNode(node);
    }

    return m_ast;
  }

  std::shared_ptr<AST> Parser::parseFactor() {
    switch (m_lexer.token()->type) {
      case Token::Type::L_PAREN:
        return parseCall();
      case Token::Type::NUMBER:
        return parseNumber();
      case Token::Type::ID:
        return parseID();
      case Token::Type::STRING:
        return parseString();
      default:
        Lexer::assertType(m_lexer.token()->type, Token::Type::END);
        throw "Unexpected token";
    }
  }

  std::shared_ptr<AST::Number> Parser::parseNumber() {
    auto number = std::static_pointer_cast<Token::Number>(m_lexer.token(Token::Type::NUMBER));
    return std::make_shared<AST::Number>(number->value);
  }

  std::shared_ptr<AST::ID> Parser::parseID() {
    auto id = std::static_pointer_cast<Token::ID>(m_lexer.token(Token::Type::ID));
    auto astID = std::make_shared<AST::ID>(id->name);

    m_ast->strings.push_back(id->name);

    return astID;
  }

  std::shared_ptr<AST::String> Parser::parseString() {
    auto string = std::static_pointer_cast<Token::String>(m_lexer.token(Token::Type::STRING));
    auto astString = std::make_shared<AST::String>(string->value);

    m_ast->strings.push_back(string->value);

    return astString;
  }

  std::shared_ptr<AST::Call> Parser::parseCall(void) {
    m_lexer.ensure(Token::Type::L_PAREN);

    auto call = std::make_shared<AST::Call>();

    while (m_lexer.token()->type != Token::Type::R_PAREN) {
      call->arguments.push_back(parseFactor());
    }

    m_lexer.ensure(Token::Type::R_PAREN);

    return call;
  }

}

module ConditionalStructuresSpec where

import Test.Hspec
import Utils
import Grammar
import Lexer


spec :: Spec
spec = do
    describe "Classic Selection" $ do
        let buildProgram c = "\
        \ hello ashen one \

        \ traveling somewhere \
        \   trust your inventory \
        \   " ++ c ++ " \
        \   inventory closed \
        \ you died \

        \ farewell ashen one"

        it "rejects empty selection block" $
            runTestForInvalidProgram $ buildProgram ""
        it "rejects selection block with only an else statement" $
            runTestForInvalidProgram $ buildProgram "\
            \ liar!: \
            \   traveling somewhere \
            \       with orange saponite say @hello world@ \
            \   you died"
        it "accepts a selection block with only one if statment" $
            runTestForValidProgram (buildProgram "\
            \ lit: \
            \   traveling somewhere \
            \       with orange saponite say @hello world@ \
            \ you died") (\(Program (CodeBlock [InstIf [
                GuardedCase
                    TrueLit
                    (CodeBlock [InstPrint (StringLit "hello world")])
                ]])) -> True)

        it "accepts a selection block with sevearal if/elseif statments and parses them in order" $
            runTestForValidProgram (buildProgram "\
            \ lit: \
            \   traveling somewhere \
            \       with orange saponite say @hello world@ \
            \   you died \
            \ unlit: \
            \   traveling somewhere \
            \       with orange saponite say @goodbye@ \
            \   you died") (\(Program (CodeBlock [InstIf [
                GuardedCase
                    TrueLit
                    (CodeBlock [InstPrint (StringLit "hello world")]),
                GuardedCase FalseLit (CodeBlock [InstPrint (StringLit "goodbye")])
                ]])) -> True)

        it "accepts a selection block with an if and else statment" $
            runTestForValidProgram (buildProgram "\
            \ lit: \
            \   traveling somewhere \
            \       with orange saponite say @hello world@ \
            \   you died \
            \ liar!: \
            \   traveling somewhere \
            \       with orange saponite say @goodbye@ \
            \   you died") (\(Program (CodeBlock [InstIf [
                GuardedCase
                    TrueLit
                    (CodeBlock [InstPrint (StringLit "hello world")]),
                ElseCase (CodeBlock [InstPrint (StringLit "goodbye")])
                ]])) -> True)
        it "rejects a selection block with more than 1 else statment" $
            runTestForInvalidProgram $ buildProgram "\
            \ lit: \
            \   traveling somewhere \
            \       with orange saponite say @hello world@ \
            \   you died \
            \ liar!: \
            \   traveling somewhere \
            \       with orange saponite say @hello world@ \
            \   you died \
            \ liar!: \
            \   traveling somewhere \
            \       with orange saponite say @hello world@ \
            \   you died"
    describe "Switch statements" $ do
        let buildProgram c = "\
        \ hello ashen one \

        \ traveling somewhere \
        \   enter dungeon with a \
        \   " ++ c ++ " \
        \   dungeon exited \
        \ you died \

        \ farewell ashen one"

        it "rejects an empty switch statement" $
            runTestForInvalidProgram $ buildProgram ""
        it "rejects switch statament with only default" $
            runTestForInvalidProgram $ buildProgram "\
            \ empty dungeon: \
            \   traveling somewhere \
            \       with orange saponite say @hello@ \
            \   you died"
        it "accepts switch statament with only one case" $
            runTestForValidProgram (buildProgram "\
            \ 1: \
            \   traveling somewhere \
            \       with orange saponite say @hello@ \
            \   you died") (\(Program (CodeBlock [InstSwitch (Id (Token _ (Just "a") _)) [
                    Case (IntLit 1) (CodeBlock [InstPrint (StringLit "hello")])
                ]])) -> True)

        it "rejects switch statement with more than 1 default" $
            runTestForInvalidProgram $ buildProgram "\
            \ 1: \
            \   traveling somewhere \
            \       with orange saponite say @hello@ \
            \   you died \
            \ empty dungeon: \
            \   traveling somewhere \
            \       with orange saponite say @hello@ \
            \   you died \
            \ empty dungeon: \
            \   traveling somewhere \
            \       with orange saponite say @hello@ \
            \   you died "
        it "accepts swith statement with several non-default cases" $
            runTestForValidProgram (buildProgram "\
            \ 1: \
            \   traveling somewhere \
            \       with orange saponite say @hello@ \
            \   you died \
            \ 2: \
            \   traveling somewhere \
            \       with orange saponite say @bye@ \
            \   you died") (\(Program (CodeBlock [InstSwitch (Id (Token _ (Just "a") _)) [
                    Case (IntLit 1) (CodeBlock [InstPrint (StringLit "hello")]),
                    Case (IntLit 2) (CodeBlock [InstPrint (StringLit "bye")])
                ]])) -> True)

        it "accepts swith statement with several non-default cases and one default" $
            runTestForValidProgram (buildProgram "\
            \ 1: \
            \   traveling somewhere \
            \       with orange saponite say @hello@ \
            \   you died \
            \ 2: \
            \   traveling somewhere \
            \       with orange saponite say @bye@ \
            \   you died \
            \ empty dungeon: \
            \   traveling somewhere \
            \       with orange saponite say @empty@ \
            \   you died") (\(Program (CodeBlock [InstSwitch (Id (Token _ (Just "a") _)) [
                    Case (IntLit 1) (CodeBlock [InstPrint (StringLit "hello")]),
                    Case (IntLit 2) (CodeBlock [InstPrint (StringLit "bye")]),
                    DefaultCase (CodeBlock [InstPrint (StringLit "empty")])
                ]])) -> True)


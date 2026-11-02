#include "person.h"

#include <QDebug>

using namespace Qt::StringLiterals;

namespace app {
namespace model {

Person::Person(QObject *parent)
    : QObject(parent)
    , mName{u"x"_s}
    , mIsValid(false)
{
    int a{3};
}

Person::~Person() = default;

QString Person::name() const
{
    return mName;
}

} // namespace model
} // namespace app

void app::model::Person::refresh()
{
}
